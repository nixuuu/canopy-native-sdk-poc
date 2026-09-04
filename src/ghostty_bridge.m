// AppKit host for the pinned full Ghostty C API. Native SDK owns chrome only.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include "ghostty.h"
#include "ghostty_bridge.h"
#include "ghostty_activity.h"
#include "ghostty_input.h"

_Static_assert(sizeof(canopy_ghostty_event_kind) == sizeof(int), "bridge event ABI changed");
_Static_assert(sizeof(canopy_ghostty_env) == sizeof(ghostty_env_var_s), "Ghostty environment ABI changed");
_Static_assert(offsetof(canopy_ghostty_env, value) == offsetof(ghostty_env_var_s, value), "Ghostty environment layout changed");

@class CanopyGhosttyHost;
@interface CanopyGhosttyView : NSView <NSTextInputClient>
@property(nonatomic, assign) ghostty_surface_t surface;
@property(nonatomic, weak) CanopyGhosttyHost *host;
@property(nonatomic, assign) uint64_t tab;
@property(nonatomic, strong) NSMutableAttributedString *marked;
@property(nonatomic, strong) NSEvent *keyEvent;
@property(nonatomic, assign) BOOL keySent;
@property(nonatomic, assign) NSEventModifierFlags translationFlags;
@property(nonatomic, strong) NSTrackingArea *tracking;
@property(nonatomic, assign) BOOL displayVisible;
@property(nonatomic, assign) BOOL responderFocused;
@property(nonatomic, assign) CanopyTerminalFocusGate focusGate;
@property(nonatomic, assign) BOOL visibilityKnown;
@property(nonatomic, assign) BOOL appliedVisible;
@property(nonatomic, assign) BOOL sidebarOverlay;
@property(nonatomic, assign) BOOL suppressMouseUp;
@property(nonatomic, assign) double appliedScale;
@property(nonatomic, assign) uint32_t appliedPixelWidth;
@property(nonatomic, assign) uint32_t appliedPixelHeight;
@property(nonatomic, assign) uint32_t appliedDisplayID;
- (void)syncSize;
- (void)syncOcclusion;
- (void)syncFocus;
@end

@interface CanopyGhosttyHost : NSObject
@property(nonatomic, assign) ghostty_app_t app;
@property(nonatomic, assign) ghostty_config_t config;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, CanopyGhosttyView *> *views;
@property(nonatomic, strong) NSMutableArray<NSValue *> *events;
@property(nonatomic, assign) BOOL stopping;
@property(nonatomic, assign) BOOL dark;
@property(nonatomic, assign) BOOL focused;
@property(nonatomic, assign) void (*notify)(void *);
@property(nonatomic, assign) void *notifyContext;
- (void)queue:(uint64_t)tab kind:(canopy_ghostty_event_kind)kind code:(int)code;
@end

static ghostty_input_mods_e mods(NSEventModifierFlags flags) {
    unsigned value = 0;
    if (flags & NSEventModifierFlagShift) value |= GHOSTTY_MODS_SHIFT;
    if (flags & NSEventModifierFlagControl) value |= GHOSTTY_MODS_CTRL;
    if (flags & NSEventModifierFlagOption) value |= GHOSTTY_MODS_ALT;
    if (flags & NSEventModifierFlagCommand) value |= GHOSTTY_MODS_SUPER;
    if (flags & NSEventModifierFlagCapsLock) value |= GHOSTTY_MODS_CAPS;
    return (ghostty_input_mods_e)value;
}

@implementation CanopyGhosttyView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    // AppKit can consume the activating click before mouseDown/local monitors.
    // Claim the keyboard here, but do not opt into click-through: activating a
    // terminal must not also click a button or start a selection in its TUI.
    [self.window makeFirstResponder:self];
    return NO;
}
- (BOOL)becomeFirstResponder {
    BOOL accepted = [super becomeFirstResponder];
    if (accepted) { self.responderFocused = YES; [self syncFocus]; }
    return accepted;
}
- (BOOL)resignFirstResponder {
    BOOL accepted = [super resignFirstResponder];
    if (accepted) { self.responderFocused = NO; [self syncFocus]; }
    return accepted;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    // This app-owned adoption container preserves its edge insets while the
    // window is resized. Ghostty can resize natively even when canvas layout
    // rebuilds are coalesced to the next display tick.
    if (self.superview) self.superview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self];
    self.responderFocused = self.window && self.window.firstResponder == self;
    if (self.window) {
        for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
                                          NSWindowDidChangeOcclusionStateNotification, NSWindowDidMiniaturizeNotification,
                                          NSWindowDidDeminiaturizeNotification]) {
            [center addObserver:self selector:@selector(activityChanged:) name:name object:self.window];
        }
        for (NSNotificationName name in @[NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification]) {
            [center addObserver:self selector:@selector(activityChanged:) name:name object:NSApp];
        }
    }
    [self syncSize]; [self syncOcclusion];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)activityChanged:(NSNotification *)notification { [self syncOcclusion]; }
- (void)syncOcclusion {
    if (!self.surface) return;
    BOOL visible = self.displayVisible && self.window && !self.window.miniaturized &&
        !self.isHiddenOrHasHiddenAncestor && (self.window.occlusionState & NSWindowOcclusionStateVisible);
    if (!self.visibilityKnown || visible != self.appliedVisible) {
        self.visibilityKnown = YES;
        self.appliedVisible = visible;
        ghostty_surface_set_occlusion(self.surface, visible);
    }
    [self syncFocus];
}
- (void)syncFocus {
    if (!self.surface) return;
    CanopyTerminalFocusGate gate = self.focusGate;
    CanopyTerminalFocusState state = {
        .app_active = NSApp.active,
        .window_key = self.window && self.window.isKeyWindow,
        .responder = self.responderFocused,
        .presented = self.displayVisible && self.window != nil,
        .visible = self.appliedVisible,
    };
    if (CanopyTerminalFocusUpdate(&gate, state)) {
        self.focusGate = gate;
        ghostty_surface_set_focus(self.surface, gate.focused);
        // Edge-only diagnostics: never log terminal contents or sample on a timer.
        const char *trace = getenv("CANOPY_GHOSTTY_ACTIVITY_TRACE");
        if (trace && strcmp(trace, "1") == 0) {
            fprintf(stderr, "canopy: terminal-activity tab=%llu focus=%d app=%d key=%d responder=%d presented=%d visible=%d\n",
                    (unsigned long long)self.tab, gate.focused, state.app_active, state.window_key,
                    state.responder, state.presented, state.visible);
        }
    }
}
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self syncSize]; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self syncSize]; }
- (void)syncSize {
    if (!self.surface) return;
    double scale = self.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor;
    if (scale != self.appliedScale) {
        ghostty_surface_set_content_scale(self.surface, scale, scale);
        self.appliedScale = scale;
    }
    uint32_t width = MAX(1, lround(self.bounds.size.width * scale));
    uint32_t height = MAX(1, lround(self.bounds.size.height * scale));
    if (width != self.appliedPixelWidth || height != self.appliedPixelHeight) {
        ghostty_surface_set_size(self.surface, width, height);
        self.appliedPixelWidth = width;
        self.appliedPixelHeight = height;
    }
    NSNumber *display = self.window.screen.deviceDescription[@"NSScreenNumber"];
    // The C API enqueues into the renderer's bounded mailbox and updates its
    // display link. A window resize is not a monitor change.
    if (display && display.unsignedIntValue != self.appliedDisplayID) {
        ghostty_surface_set_display_id(self.surface, display.unsignedIntValue);
        self.appliedDisplayID = display.unsignedIntValue;
    }
}
- (void)sendKey:(NSEvent *)event text:(NSString *)text action:(ghostty_input_action_e)action {
    if (!self.surface || self.sidebarOverlay) return;
    ghostty_input_key_s key = {0};
    key.action = action;
    key.keycode = event.keyCode;
    key.mods = mods(event.modifierFlags);
    key.consumed_mods = mods((self.keyEvent ? self.translationFlags : event.modifierFlags) & ~(NSEventModifierFlagControl | NSEventModifierFlagCommand));
    // Ghostty encodes controls itself (including Ctrl+C and Ctrl+Enter).
    key.text = text.length && [text characterAtIndex:0] >= 0x20 ? text.UTF8String : NULL;
    NSString *unshifted = [event charactersByApplyingModifiers:0];
    if (unshifted.length) {
        unichar first = [unshifted characterAtIndex:0];
        key.unshifted_codepoint = CFStringIsSurrogateHighCharacter(first) && unshifted.length > 1 ? CFStringGetLongCharacterForSurrogatePair(first, [unshifted characterAtIndex:1]) : first;
    }
    key.composing = self.hasMarkedText;
    ghostty_surface_key(self.surface, key);
    self.keySent = YES;
}
- (void)keyDown:(NSEvent *)event {
    if (self.sidebarOverlay) {
        if (event.keyCode == 53) [self.host queue:self.tab kind:CANOPY_GHOSTTY_DISMISS_SIDEBAR code:0];
        return;
    }
    self.keyEvent = event;
    self.keySent = NO;
    ghostty_input_mods_e translated = self.surface ? ghostty_surface_key_translation_mods(self.surface, mods(event.modifierFlags)) : mods(event.modifierFlags);
    NSEventModifierFlags flags = event.modifierFlags;
    const NSEventModifierFlags nativeFlags[] = {NSEventModifierFlagShift,NSEventModifierFlagControl,NSEventModifierFlagOption,NSEventModifierFlagCommand};
    const unsigned ghosttyFlags[] = {GHOSTTY_MODS_SHIFT,GHOSTTY_MODS_CTRL,GHOSTTY_MODS_ALT,GHOSTTY_MODS_SUPER};
    for (int i=0;i<4;i++) { if (translated & ghosttyFlags[i]) flags |= nativeFlags[i]; else flags &= ~nativeFlags[i]; }
    self.translationFlags = flags;
    NSEvent *translation = event;
    if (flags != event.modifierFlags) translation = [NSEvent keyEventWithType:event.type location:event.locationInWindow modifierFlags:flags timestamp:event.timestamp windowNumber:event.windowNumber context:nil characters:[event charactersByApplyingModifiers:flags] ?: @"" charactersIgnoringModifiers:event.charactersIgnoringModifiers ?: @"" isARepeat:event.isARepeat keyCode:event.keyCode] ?: event;
    [self interpretKeyEvents:@[translation]];
    if (!self.keySent && !self.hasMarkedText) [self sendKey:event text:nil action:event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS];
    self.keyEvent = nil;
}
- (void)keyUp:(NSEvent *)event { [self sendKey:event text:nil action:GHOSTTY_ACTION_RELEASE]; }
- (void)doCommandBySelector:(SEL)selector { if (self.keyEvent) [self sendKey:self.keyEvent text:nil action:GHOSTTY_ACTION_PRESS]; }
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (!self.surface || self.window.firstResponder != self) return NO;
    ghostty_input_key_s key = {0};
    key.action = GHOSTTY_ACTION_PRESS; key.keycode = event.keyCode; key.mods = mods(event.modifierFlags);
    if (!ghostty_surface_key_is_binding(self.surface, key, NULL)) return NO;
    ghostty_surface_key(self.surface, key);
    return YES;
}
- (void)insertText:(id)value replacementRange:(NSRange)range {
    if (self.sidebarOverlay) return;
    NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] : value;
    BOOL composed = self.hasMarkedText;
    [self unmarkText];
    if (!self.surface) return;
    if (self.keyEvent && !composed) [self sendKey:self.keyEvent text:text action:self.keyEvent.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS];
    else { ghostty_surface_text(self.surface, text.UTF8String, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]); self.keySent = YES; }
}
- (void)setMarkedText:(id)value selectedRange:(NSRange)selected replacementRange:(NSRange)replacement {
    self.marked = [value isKindOfClass:NSAttributedString.class] ? [value mutableCopy] : [[NSMutableAttributedString alloc] initWithString:value];
    if (self.surface) ghostty_surface_preedit(self.surface, self.marked.string.UTF8String, [self.marked.string lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
}
- (void)unmarkText { self.marked = nil; if (self.surface) ghostty_surface_preedit(self.surface, NULL, 0); }
- (BOOL)hasMarkedText { return self.marked.length > 0; }
- (NSRange)markedRange { return self.hasMarkedText ? NSMakeRange(0, self.marked.length) : NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return NSMakeRange(NSNotFound, 0); }
- (NSArray *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual { return nil; }
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
    double x=0,y=0,w=1,h=1; if (self.surface) ghostty_surface_ime_point(self.surface,&x,&y,&w,&h);
    return [self.window convertRectToScreen:[self convertRect:NSMakeRect(x,y,w,h) toView:nil]];
}
- (void)copy:(id)sender { if (self.surface) ghostty_surface_binding_action(self.surface,"copy_to_clipboard",17); }
- (void)paste:(id)sender { if (self.surface && !self.sidebarOverlay) ghostty_surface_binding_action(self.surface,"paste_from_clipboard",20); }
- (void)mouseMoved:(NSEvent *)event { if (self.sidebarOverlay) return; NSPoint p=[self convertPoint:event.locationInWindow fromView:nil]; if(self.surface) ghostty_surface_mouse_pos(self.surface,p.x,p.y,mods(event.modifierFlags)); }
- (void)sendMouseButton:(ghostty_input_mouse_button_e)button state:(ghostty_input_mouse_state_e)state event:(NSEvent *)event {
    bool suppress = self.suppressMouseUp;
    CanopyMouseDecision decision = CanopyTerminalMouseInput(self.sidebarOverlay,
        button == GHOSTTY_MOUSE_LEFT, state == GHOSTTY_MOUSE_PRESS, &suppress);
    self.suppressMouseUp = suppress;
    if (decision == CANOPY_MOUSE_DISMISS_SIDEBAR) {
        [self.host queue:self.tab kind:CANOPY_GHOSTTY_DISMISS_SIDEBAR code:0];
        return;
    }
    if (decision == CANOPY_MOUSE_BLOCK) return;
    if (button == GHOSTTY_MOUSE_LEFT && state == GHOSTTY_MOUSE_PRESS) [self.window makeFirstResponder:self];
    [self mouseMoved:event];
    if (self.surface) ghostty_surface_mouse_button(self.surface, state, button, mods(event.modifierFlags));
}
- (void)mouseDown:(NSEvent *)event { [self sendMouseButton:GHOSTTY_MOUSE_LEFT state:GHOSTTY_MOUSE_PRESS event:event]; }
- (void)mouseUp:(NSEvent *)event { [self sendMouseButton:GHOSTTY_MOUSE_LEFT state:GHOSTTY_MOUSE_RELEASE event:event]; }
- (void)mouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)rightMouseDown:(NSEvent *)event { [self sendMouseButton:GHOSTTY_MOUSE_RIGHT state:GHOSTTY_MOUSE_PRESS event:event]; }
- (void)rightMouseUp:(NSEvent *)event { [self sendMouseButton:GHOSTTY_MOUSE_RIGHT state:GHOSTTY_MOUSE_RELEASE event:event]; }
- (void)rightMouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)otherMouseDown:(NSEvent *)event { [self sendMouseButton:GHOSTTY_MOUSE_MIDDLE state:GHOSTTY_MOUSE_PRESS event:event]; }
- (void)otherMouseUp:(NSEvent *)event { [self sendMouseButton:GHOSTTY_MOUSE_MIDDLE state:GHOSTTY_MOUSE_RELEASE event:event]; }
- (void)otherMouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)mouseExited:(NSEvent *)event { if(self.surface) ghostty_surface_mouse_pos(self.surface,-1,-1,mods(event.modifierFlags)); }
- (void)scrollWheel:(NSEvent *)event {
    if (self.sidebarOverlay) return;
    unsigned momentum=GHOSTTY_MOUSE_MOMENTUM_NONE;
    switch(event.momentumPhase) {
        case NSEventPhaseBegan: momentum=GHOSTTY_MOUSE_MOMENTUM_BEGAN; break;
        case NSEventPhaseStationary: momentum=GHOSTTY_MOUSE_MOMENTUM_STATIONARY; break;
        case NSEventPhaseChanged: momentum=GHOSTTY_MOUSE_MOMENTUM_CHANGED; break;
        case NSEventPhaseEnded: momentum=GHOSTTY_MOUSE_MOMENTUM_ENDED; break;
        case NSEventPhaseCancelled: momentum=GHOSTTY_MOUSE_MOMENTUM_CANCELLED; break;
        case NSEventPhaseMayBegin: momentum=GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN; break;
        default: break;
    }
    double factor=event.hasPreciseScrollingDeltas ? 2 : 1;
    if(self.surface) ghostty_surface_mouse_scroll(self.surface,event.scrollingDeltaX*factor,event.scrollingDeltaY*factor,(momentum<<1) | (event.hasPreciseScrollingDeltas ? 1 : 0));
}
@end

@implementation CanopyGhosttyHost
- (void)queue:(uint64_t)tab kind:(canopy_ghostty_event_kind)kind code:(int)code {
    if (self.stopping) return;
    canopy_ghostty_event event = {tab,kind,code};
    [self.events addObject:[NSValue valueWithBytes:&event objCType:@encode(canopy_ghostty_event)]];
    if (self.events.count == 1 && self.notify) self.notify(self.notifyContext);
}
@end

static void wakeup(void *userdata) {
    CanopyGhosttyHost *host = (__bridge CanopyGhosttyHost *)userdata;
    dispatch_async(dispatch_get_main_queue(), ^{ if (!host.stopping && host.app) ghostty_app_tick(host.app); });
}
static bool action(ghostty_app_t app, ghostty_target_s target, ghostty_action_s action) {
    CanopyGhosttyHost *host = (__bridge CanopyGhosttyHost *)ghostty_app_userdata(app);
    if (host.stopping) return false;
    CanopyGhosttyView *view = target.tag == GHOSTTY_TARGET_SURFACE ? (__bridge CanopyGhosttyView *)ghostty_surface_userdata(target.target.surface) : nil;
    switch (action.tag) {
        case GHOSTTY_ACTION_RENDER: if (view.surface) ghostty_surface_draw(view.surface); return true;
        // The pinned Ghostty macOS login wrapper does not reliably preserve
        // the command's exit code (see Surface.childExited). Do not report 0.
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED: if(view) [host queue:view.tab kind:CANOPY_GHOSTTY_PROCESS_EXIT code:-1]; return true;
        case GHOSTTY_ACTION_CLOSE_TAB: if(view) [host queue:view.tab kind:CANOPY_GHOSTTY_CLOSE_TAB code:0]; return view != nil;
        case GHOSTTY_ACTION_NEW_TAB: if(view) [host queue:view.tab kind:CANOPY_GHOSTTY_NEW_TERMINAL code:0]; return view != nil;
        case GHOSTTY_ACTION_SET_TITLE: case GHOSTTY_ACTION_PWD: case GHOSTTY_ACTION_CELL_SIZE: case GHOSTTY_ACTION_INITIAL_SIZE: case GHOSTTY_ACTION_SIZE_LIMIT: case GHOSTTY_ACTION_SCROLLBAR: return true;
        default: return false;
    }
}
static void closeSurface(void *userdata, bool alive) { CanopyGhosttyView *view=(__bridge CanopyGhosttyView *)userdata; [view.host queue:view.tab kind:CANOPY_GHOSTTY_CLOSE_TAB code:0]; }
static bool readClipboard(void *userdata, ghostty_clipboard_e clipboard, void *state) {
    CanopyGhosttyView *view=(__bridge CanopyGhosttyView *)userdata;
    if (!view.surface || clipboard != GHOSTTY_CLIPBOARD_STANDARD) return false;
    NSString *text=[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    ghostty_surface_complete_clipboard_request(view.surface,(text ?: @"").UTF8String,state,false); return true;
}
static void confirmClipboard(void *userdata, const char *text, void *state, ghostty_clipboard_request_e request) {
    // Never auto-approve OSC 52 or a paste needing user confirmation.
    CanopyGhosttyView *view=(__bridge CanopyGhosttyView *)userdata;
    if(view.surface) ghostty_surface_complete_clipboard_request(view.surface,"",state,true);
}
static void writeClipboard(void *userdata, ghostty_clipboard_e clipboard, const ghostty_clipboard_content_s *contents, size_t count, bool confirm) {
    if (confirm || clipboard != GHOSTTY_CLIPBOARD_STANDARD) return;
    for(size_t i=0;i<count;i++) if(contents[i].mime && strcmp(contents[i].mime,"text/plain")==0) {
        NSString *text=[NSString stringWithUTF8String:contents[i].data ?: ""];
        [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString]; break;
    }
}

void *canopy_ghostty_create(const char *const *files, size_t count) {
    static dispatch_once_t once; static int initialized;
    dispatch_once(&once, ^{
        if (!getenv("GHOSTTY_RESOURCES_DIR")) {
            NSArray *candidates=@[[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"ghostty"],
                [[[NSProcessInfo.processInfo.arguments.firstObject stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../share/ghostty"] stringByStandardizingPath],
                [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"zig-out/ghostty/share/ghostty"]];
            for(NSString *path in candidates) if([NSFileManager.defaultManager fileExistsAtPath:path]) { setenv("GHOSTTY_RESOURCES_DIR",path.UTF8String,0); break; }
        }
        char *argv[]={(char *)"canopy-native-sdk-poc",NULL}; initialized=ghostty_init(1,argv);
    });
    if(initialized != GHOSTTY_SUCCESS) return NULL;
    CanopyGhosttyHost *host=[CanopyGhosttyHost new]; host.views=[NSMutableDictionary new]; host.events=[NSMutableArray new];
    host.config=ghostty_config_new(); if(!host.config) return NULL;
    for(size_t i=0;i<count;i++) ghostty_config_load_file(host.config,files[i]);
    ghostty_config_finalize(host.config);
    uint32_t diagnostics=ghostty_config_diagnostics_count(host.config);
    if(diagnostics) fprintf(stderr,"canopy: Ghostty reported %u configuration diagnostics\n",diagnostics);
    ghostty_runtime_config_s runtime={0}; runtime.userdata=(__bridge void *)host;
    runtime.wakeup_cb=wakeup; runtime.action_cb=action; runtime.close_surface_cb=closeSurface;
    runtime.read_clipboard_cb=readClipboard; runtime.confirm_read_clipboard_cb=confirmClipboard; runtime.write_clipboard_cb=writeClipboard;
    host.app=ghostty_app_new(&runtime,host.config);
    if(!host.app) { ghostty_config_free(host.config); return NULL; }
    host.focused=NSApp.active;
    host.dark=[[NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    ghostty_app_set_focus(host.app,host.focused);
    ghostty_app_set_color_scheme(host.app,host.dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT);
    return (__bridge_retained void *)host;
}
void *canopy_ghostty_surface(void *raw, uint64_t tab, const char *cwd, const char *command, const canopy_ghostty_env *env, size_t count) {
    CanopyGhosttyHost *host=(__bridge CanopyGhosttyHost *)raw;
    if(host.views[@(tab)]) return (__bridge void *)host.views[@(tab)];
    CanopyGhosttyView *view=[[CanopyGhosttyView alloc] initWithFrame:NSMakeRect(0,0,800,600)]; view.tab=tab; view.host=host;
    ghostty_surface_config_s options=ghostty_surface_config_new(); options.platform_tag=GHOSTTY_PLATFORM_MACOS; options.platform.macos.nsview=(__bridge void *)view;
    options.userdata=(__bridge void *)view; options.working_directory=cwd; options.command=command;
    options.scale_factor=NSScreen.mainScreen.backingScaleFactor; options.context=GHOSTTY_SURFACE_CONTEXT_TAB;
    options.env_vars=(ghostty_env_var_s *)env; options.env_var_count=count; options.wait_after_command=true;
    view.surface=ghostty_surface_new(host.app,&options);
    if(!view.surface) return NULL;
    host.views[@(tab)]=view; [view syncSize]; [view syncOcclusion]; return (__bridge void *)view;
}
void canopy_ghostty_set_wakeup(void *raw, void (*notify)(void *), void *context) {
    CanopyGhosttyHost *host=(__bridge CanopyGhosttyHost *)raw;
    host.notify=notify; host.notifyContext=context;
}
void canopy_ghostty_close(void *raw, uint64_t tab) {
    CanopyGhosttyHost *host=(__bridge CanopyGhosttyHost *)raw; CanopyGhosttyView *view=host.views[@(tab)];
    if(!view) return; [view removeFromSuperview];
    ghostty_surface_t surface=view.surface; view.surface=NULL;
    if(surface) ghostty_surface_free(surface); [host.views removeObjectForKey:@(tab)];
}
void canopy_ghostty_visibility(void *raw, uint64_t tab, bool visible, bool focus) {
    CanopyGhosttyHost *host=(__bridge CanopyGhosttyHost *)raw; CanopyGhosttyView *view=host.views[@(tab)];
    if(!view.surface) return;
    view.displayVisible=visible;
    [view syncOcclusion];
    if(focus && visible) [view.window makeFirstResponder:view];
    [view syncFocus];
}
void canopy_ghostty_begin_layout(void *raw, uint64_t tab) {
    CanopyGhosttyView *view=((__bridge CanopyGhosttyHost *)raw).views[@(tab)];
    // Container clipping is not a terminal resize. Suppress AppKit's temporary
    // child resize until the full (uncropped) frame is applied below.
    view.autoresizingMask = NSViewNotSizable;
}
void canopy_ghostty_cover(void *raw, uint64_t tab, double covered, bool overlay) {
    CanopyGhosttyView *view=((__bridge CanopyGhosttyHost *)raw).views[@(tab)];
    view.sidebarOverlay = overlay;
    if (!view.superview) return;
    // Crop the native container, not the terminal grid: opening navigation
    // must not resize the PTY or wrap its output. Its exposed right side stays
    // live; the uncovered canvas owns sidebar input and drawing on the left.
    view.superview.wantsLayer = YES;
    view.superview.layer.masksToBounds = YES;
    NSRect bounds = view.superview.bounds;
    NSRect frame = NSMakeRect(-covered, 0, bounds.size.width + covered, bounds.size.height);
    if (!NSEqualRects(view.frame, frame)) view.frame = frame;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}
void canopy_ghostty_tick(void *raw) {
    CanopyGhosttyHost *host=(__bridge CanopyGhosttyHost *)raw;
    if(host.stopping) return;
    BOOL focused=NSApp.active;
    BOOL dark=[[NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    if(focused != host.focused) {
        host.focused=focused;
        ghostty_app_set_focus(host.app,focused);
        for (NSNumber *tab in host.views) [host.views[tab] syncFocus];
    }
    if(dark != host.dark) { host.dark=dark; ghostty_app_set_color_scheme(host.app,dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT); }
    ghostty_app_tick(host.app);
}
bool canopy_ghostty_next_event(void *raw, canopy_ghostty_event *event) {
    CanopyGhosttyHost *host=(__bridge CanopyGhosttyHost *)raw; if(host.events.count==0) return false;
    [host.events.firstObject getValue:event size:sizeof(*event)]; [host.events removeObjectAtIndex:0]; return true;
}
void canopy_ghostty_destroy(void *raw) {
    if(!raw) return; CanopyGhosttyHost *host=(__bridge_transfer CanopyGhosttyHost *)raw; host.stopping=YES;
    for(NSNumber *tab in host.views.allKeys) canopy_ghostty_close((__bridge void *)host,tab.unsignedLongLongValue);
    ghostty_app_free(host.app); host.app=NULL; ghostty_config_free(host.config); host.config=NULL;
}
