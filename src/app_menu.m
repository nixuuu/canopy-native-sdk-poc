// Override just the application's close command; preserve SDK Edit/Window menus.
#import <AppKit/AppKit.h>

@interface CanopyCloseTabMenu : NSObject <NSMenuItemValidation>
@property(nonatomic, strong) NSMenuItem *item;
@property(nonatomic, copy) NSString *originalTitle;
@property(nonatomic, assign) SEL originalAction;
@property(nonatomic, weak) id originalTarget;
@property(nonatomic, assign) BOOL canClose;
@property(nonatomic, assign) NSUInteger requests;
@property(nonatomic, assign) void (*notify)(void *);
@property(nonatomic, assign) void *context;
@end

@implementation CanopyCloseTabMenu
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    return self.canClose && !NSApp.modalWindow && !NSApp.keyWindow.sheetParent;
}
- (void)closeTab:(id)sender {
    if (![self validateMenuItem:self.item]) return;
    if (self.requests < NSUIntegerMax) self.requests++;
    if (self.requests == 1) self.notify(self.context);
}
@end

static NSMenuItem *findCloseWindow(NSMenu *menu) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == @selector(performClose:) &&
            [item.keyEquivalent.lowercaseString isEqualToString:@"w"] &&
            item.keyEquivalentModifierMask == NSEventModifierFlagCommand) return item;
        NSMenuItem *found = item.submenu ? findCloseWindow(item.submenu) : nil;
        if (found) return found;
    }
    return nil;
}

void *canopy_close_tab_menu_create(void (*notify)(void *), void *context) {
    NSMenuItem *item = findCloseWindow(NSApp.mainMenu);
    if (!item) return NULL;
    CanopyCloseTabMenu *menu = [CanopyCloseTabMenu new];
    menu.item = item;
    menu.originalTitle = item.title;
    menu.originalAction = item.action;
    menu.originalTarget = item.target;
    menu.notify = notify;
    menu.context = context;
    item.title = @"Close Tab";
    item.target = menu;
    item.action = @selector(closeTab:);
    item.enabled = NO;
    return (__bridge_retained void *)menu;
}

void canopy_close_tab_menu_update(void *raw, bool enabled) {
    CanopyCloseTabMenu *menu = (__bridge CanopyCloseTabMenu *)raw;
    menu.canClose = enabled;
    menu.item.enabled = enabled;
}

bool canopy_close_tab_menu_take(void *raw) {
    CanopyCloseTabMenu *menu = (__bridge CanopyCloseTabMenu *)raw;
    if (!menu.requests) return false;
    menu.requests--;
    return true;
}

void canopy_close_tab_menu_destroy(void *raw) {
    CanopyCloseTabMenu *menu = (__bridge_transfer CanopyCloseTabMenu *)raw;
    menu.item.title = menu.originalTitle;
    menu.item.action = menu.originalAction;
    menu.item.target = menu.originalTarget;
    menu.item.enabled = YES;
}
