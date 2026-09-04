// AppKit host for the pinned full Ghostty C API. Native SDK owns chrome only.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include "ghostty.h"
#include "ghostty_bridge.h"
#include "ghostty_activity.h"
#include "ghostty_input.h"

_Static_assert(sizeof(canopy_ghostty_event_kind) == sizeof(int), "bridge event ABI changed");
_Static_assert(sizeof(canopy_ghostty_env) == sizeof(ghostty_env_var_s),
               "Ghostty environment ABI changed");
_Static_assert(offsetof(canopy_ghostty_env, value) == offsetof(ghostty_env_var_s, value),
               "Ghostty environment layout changed");

#import "ghostty_native.h"

@implementation CanopyGhosttyHost
- (void)queue:(uint64_t)tab kind:(canopy_ghostty_event_kind)kind code:(int)code {
    if (self.stopping)
        return;
    canopy_ghostty_event event = {tab, kind, code};
    [self.events addObject:[NSValue valueWithBytes:&event objCType:@encode(canopy_ghostty_event)]];
    if (self.events.count == 1 && self.notify)
        self.notify(self.notifyContext);
}
@end

static void wakeup(void *userdata) {
    CanopyGhosttyHost *host = (__bridge CanopyGhosttyHost *)userdata;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!host.stopping && host.app)
          ghostty_app_tick(host.app);
    });
}
static bool action(ghostty_app_t app, ghostty_target_s target, ghostty_action_s action) {
    CanopyGhosttyHost *host = (__bridge CanopyGhosttyHost *)ghostty_app_userdata(app);
    if (host.stopping)
        return false;
    CanopyGhosttyView *view =
        target.tag == GHOSTTY_TARGET_SURFACE
            ? (__bridge CanopyGhosttyView *)ghostty_surface_userdata(target.target.surface)
            : nil;
    switch (action.tag) {
    case GHOSTTY_ACTION_RENDER:
        if (view.surface)
            ghostty_surface_draw(view.surface);
        return true;
    // The pinned Ghostty macOS login wrapper does not reliably preserve
    // the command's exit code (see Surface.childExited). Do not report 0.
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        if (view)
            [host queue:view.tab kind:CANOPY_GHOSTTY_PROCESS_EXIT code:-1];
        return true;
    case GHOSTTY_ACTION_CLOSE_TAB:
        if (view)
            [host queue:view.tab kind:CANOPY_GHOSTTY_CLOSE_TAB code:0];
        return view != nil;
    case GHOSTTY_ACTION_NEW_TAB:
        if (view)
            [host queue:view.tab kind:CANOPY_GHOSTTY_NEW_TERMINAL code:0];
        return view != nil;
    case GHOSTTY_ACTION_SET_TITLE:
    case GHOSTTY_ACTION_PWD:
    case GHOSTTY_ACTION_CELL_SIZE:
    case GHOSTTY_ACTION_INITIAL_SIZE:
    case GHOSTTY_ACTION_SIZE_LIMIT:
    case GHOSTTY_ACTION_SCROLLBAR:
        return true;
    default:
        return false;
    }
}
static void closeSurface(void *userdata, bool alive) {
    CanopyGhosttyView *view = (__bridge CanopyGhosttyView *)userdata;
    [view.host queue:view.tab kind:CANOPY_GHOSTTY_CLOSE_TAB code:0];
}
static bool readClipboard(void *userdata, ghostty_clipboard_e clipboard, void *state) {
    CanopyGhosttyView *view = (__bridge CanopyGhosttyView *)userdata;
    if (!view.surface || clipboard != GHOSTTY_CLIPBOARD_STANDARD)
        return false;
    NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    ghostty_surface_complete_clipboard_request(view.surface, (text ?: @"").UTF8String, state,
                                               false);
    return true;
}
static void confirmClipboard(void *userdata, const char *text, void *state,
                             ghostty_clipboard_request_e request) {
    // Never auto-approve OSC 52 or a paste needing user confirmation.
    CanopyGhosttyView *view = (__bridge CanopyGhosttyView *)userdata;
    if (view.surface)
        ghostty_surface_complete_clipboard_request(view.surface, "", state, true);
}
static void writeClipboard(void *userdata, ghostty_clipboard_e clipboard,
                           const ghostty_clipboard_content_s *contents, size_t count,
                           bool confirm) {
    if (confirm || clipboard != GHOSTTY_CLIPBOARD_STANDARD)
        return;
    for (size_t i = 0; i < count; i++)
        if (contents[i].mime && strcmp(contents[i].mime, "text/plain") == 0) {
            NSString *text = [NSString stringWithUTF8String:contents[i].data ?: ""];
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
            break;
        }
}

void *canopy_ghostty_create(const char *const *files, size_t count) {
    static dispatch_once_t once;
    static int initialized;
    dispatch_once(&once, ^{
      if (!getenv("GHOSTTY_RESOURCES_DIR")) {
          NSArray *candidates = @[
              [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"ghostty"],
              [[[NSProcessInfo.processInfo.arguments.firstObject stringByDeletingLastPathComponent]
                  stringByAppendingPathComponent:@"../share/ghostty"] stringByStandardizingPath],
              [NSFileManager.defaultManager.currentDirectoryPath
                  stringByAppendingPathComponent:@"zig-out/ghostty/share/ghostty"]
          ];
          for (NSString *path in candidates)
              if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
                  setenv("GHOSTTY_RESOURCES_DIR", path.UTF8String, 0);
                  break;
              }
      }
      char *argv[] = {(char *)"canopy-native-sdk-poc", NULL};
      initialized = ghostty_init(1, argv);
    });
    if (initialized != GHOSTTY_SUCCESS)
        return NULL;
    CanopyGhosttyHost *host = [CanopyGhosttyHost new];
    host.views = [NSMutableDictionary new];
    host.events = [NSMutableArray new];
    host.config = ghostty_config_new();
    if (!host.config)
        return NULL;
    for (size_t i = 0; i < count; i++)
        ghostty_config_load_file(host.config, files[i]);
    ghostty_config_finalize(host.config);
    uint32_t diagnostics = ghostty_config_diagnostics_count(host.config);
    if (diagnostics)
        fprintf(stderr, "canopy: Ghostty reported %u configuration diagnostics\n", diagnostics);
    ghostty_runtime_config_s runtime = {0};
    runtime.userdata = (__bridge void *)host;
    runtime.wakeup_cb = wakeup;
    runtime.action_cb = action;
    runtime.close_surface_cb = closeSurface;
    runtime.read_clipboard_cb = readClipboard;
    runtime.confirm_read_clipboard_cb = confirmClipboard;
    runtime.write_clipboard_cb = writeClipboard;
    host.app = ghostty_app_new(&runtime, host.config);
    if (!host.app) {
        ghostty_config_free(host.config);
        return NULL;
    }
    host.focused = NSApp.active;
    host.dark = [[NSApp.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
    ghostty_app_set_focus(host.app, host.focused);
    ghostty_app_set_color_scheme(host.app, host.dark ? GHOSTTY_COLOR_SCHEME_DARK
                                                     : GHOSTTY_COLOR_SCHEME_LIGHT);
    return (__bridge_retained void *)host;
}
void *canopy_ghostty_surface(void *raw, uint64_t tab, const char *cwd, const char *command,
                             const canopy_ghostty_env *env, size_t count) {
    CanopyGhosttyHost *host = (__bridge CanopyGhosttyHost *)raw;
    if (host.views[@(tab)])
        return (__bridge void *)host.views[@(tab)];
    CanopyGhosttyView *view = [[CanopyGhosttyView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    view.tab = tab;
    view.host = host;
    ghostty_surface_config_s options = ghostty_surface_config_new();
    options.platform_tag = GHOSTTY_PLATFORM_MACOS;
    options.platform.macos.nsview = (__bridge void *)view;
    options.userdata = (__bridge void *)view;
    options.working_directory = cwd;
    options.command = command;
    options.scale_factor = NSScreen.mainScreen.backingScaleFactor;
    options.context = GHOSTTY_SURFACE_CONTEXT_TAB;
    options.env_vars = (ghostty_env_var_s *)env;
    options.env_var_count = count;
    options.wait_after_command = true;
    view.surface = ghostty_surface_new(host.app, &options);
    if (!view.surface)
        return NULL;
    host.views[@(tab)] = view;
    [view syncSize];
    [view syncOcclusion];
    return (__bridge void *)view;
}
void canopy_ghostty_set_wakeup(void *raw, void (*notify)(void *), void *context) {
    CanopyGhosttyHost *host = (__bridge CanopyGhosttyHost *)raw;
    host.notify = notify;
    host.notifyContext = context;
}
void canopy_ghostty_close(void *raw, uint64_t tab) {
    CanopyGhosttyHost *host = (__bridge CanopyGhosttyHost *)raw;
    CanopyGhosttyView *view = host.views[@(tab)];
    if (!view)
        return;
    [view removeFromSuperview];
    ghostty_surface_t surface = view.surface;
    view.surface = NULL;
    if (surface)
        ghostty_surface_free(surface);
    [host.views removeObjectForKey:@(tab)];
}
void canopy_ghostty_visibility(void *raw, uint64_t tab, bool visible, bool focus) {
    CanopyGhosttyHost *host = (__bridge CanopyGhosttyHost *)raw;
    CanopyGhosttyView *view = host.views[@(tab)];
    if (!view.surface)
        return;
    view.displayVisible = visible;
    [view syncOcclusion];
    if (focus && visible)
        [view.window makeFirstResponder:view];
    [view syncFocus];
}
void canopy_ghostty_begin_layout(void *raw, uint64_t tab) {
    CanopyGhosttyView *view = ((__bridge CanopyGhosttyHost *)raw).views[@(tab)];
    // Container clipping is not a terminal resize. Suppress AppKit's temporary
    // child resize until the full (uncropped) frame is applied below.
    view.autoresizingMask = NSViewNotSizable;
}
void canopy_ghostty_cover(void *raw, uint64_t tab, double covered, bool overlay) {
    CanopyGhosttyView *view = ((__bridge CanopyGhosttyHost *)raw).views[@(tab)];
    view.sidebarOverlay = overlay;
    if (!view.superview)
        return;
    // Crop the native container, not the terminal grid: opening navigation
    // must not resize the PTY or wrap its output. Its exposed right side stays
    // live; the uncovered canvas owns sidebar input and drawing on the left.
    view.superview.wantsLayer = YES;
    view.superview.layer.masksToBounds = YES;
    NSRect bounds = view.superview.bounds;
    NSRect frame = NSMakeRect(-covered, 0, bounds.size.width + covered, bounds.size.height);
    if (!NSEqualRects(view.frame, frame))
        view.frame = frame;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}
void canopy_ghostty_tick(void *raw) {
    CanopyGhosttyHost *host = (__bridge CanopyGhosttyHost *)raw;
    if (host.stopping)
        return;
    BOOL focused = NSApp.active;
    BOOL dark = [[NSApp.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
    if (focused != host.focused) {
        host.focused = focused;
        ghostty_app_set_focus(host.app, focused);
        for (NSNumber *tab in host.views)
            [host.views[tab] syncFocus];
    }
    if (dark != host.dark) {
        host.dark = dark;
        ghostty_app_set_color_scheme(host.app,
                                     dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT);
    }
    ghostty_app_tick(host.app);
}
bool canopy_ghostty_next_event(void *raw, canopy_ghostty_event *event) {
    CanopyGhosttyHost *host = (__bridge CanopyGhosttyHost *)raw;
    if (host.events.count == 0)
        return false;
    [host.events.firstObject getValue:event size:sizeof(*event)];
    [host.events removeObjectAtIndex:0];
    return true;
}
void canopy_ghostty_destroy(void *raw) {
    if (!raw)
        return;
    CanopyGhosttyHost *host = (__bridge_transfer CanopyGhosttyHost *)raw;
    host.stopping = YES;
    for (NSNumber *tab in host.views.allKeys)
        canopy_ghostty_close((__bridge void *)host, tab.unsignedLongLongValue);
    ghostty_app_free(host.app);
    host.app = NULL;
    ghostty_config_free(host.config);
    host.config = NULL;
}
