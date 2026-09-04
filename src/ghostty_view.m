// AppKit view, input, IME and geometry adapter.
#import "ghostty_native.h"

static ghostty_input_mods_e mods(NSEventModifierFlags flags) {
    unsigned value = 0;
    if (flags & NSEventModifierFlagShift)
        value |= GHOSTTY_MODS_SHIFT;
    if (flags & NSEventModifierFlagControl)
        value |= GHOSTTY_MODS_CTRL;
    if (flags & NSEventModifierFlagOption)
        value |= GHOSTTY_MODS_ALT;
    if (flags & NSEventModifierFlagCommand)
        value |= GHOSTTY_MODS_SUPER;
    if (flags & NSEventModifierFlagCapsLock)
        value |= GHOSTTY_MODS_CAPS;
    return (ghostty_input_mods_e)value;
}

@implementation CanopyGhosttyView
- (BOOL)isFlipped {
    return YES;
}
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    // AppKit can consume the activating click before mouseDown/local monitors.
    // Claim the keyboard here, but do not opt into click-through: activating a
    // terminal must not also click a button or start a selection in its TUI.
    [self.window makeFirstResponder:self];
    return NO;
}
- (BOOL)becomeFirstResponder {
    BOOL accepted = [super becomeFirstResponder];
    if (accepted) {
        self.responderFocused = YES;
        [self syncFocus];
    }
    return accepted;
}
- (BOOL)resignFirstResponder {
    BOOL accepted = [super resignFirstResponder];
    if (accepted) {
        self.responderFocused = NO;
        [self syncFocus];
    }
    return accepted;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.tracking)
        [self removeTrackingArea:self.tracking];
    self.tracking = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                     NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    // This app-owned adoption container preserves its edge insets while the
    // window is resized. Ghostty can resize natively even when canvas layout
    // rebuilds are coalesced to the next display tick.
    if (self.superview)
        self.superview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self];
    self.responderFocused = self.window && self.window.firstResponder == self;
    if (self.window) {
        for (NSNotificationName name in @[
                 NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
                 NSWindowDidChangeOcclusionStateNotification, NSWindowDidMiniaturizeNotification,
                 NSWindowDidDeminiaturizeNotification
             ]) {
            [center addObserver:self
                       selector:@selector(activityChanged:)
                           name:name
                         object:self.window];
        }
        for (NSNotificationName name in @[
                 NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification
             ]) {
            [center addObserver:self selector:@selector(activityChanged:) name:name object:NSApp];
        }
    }
    [self syncSize];
    [self syncOcclusion];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)activityChanged:(NSNotification *)notification {
    [self syncOcclusion];
}
- (void)syncOcclusion {
    if (!self.surface)
        return;
    BOOL visible = self.displayVisible && self.window && !self.window.miniaturized &&
                   !self.isHiddenOrHasHiddenAncestor &&
                   (self.window.occlusionState & NSWindowOcclusionStateVisible);
    if (!self.visibilityKnown || visible != self.appliedVisible) {
        self.visibilityKnown = YES;
        self.appliedVisible = visible;
        ghostty_surface_set_occlusion(self.surface, visible);
    }
    [self syncFocus];
}
- (void)syncFocus {
    if (!self.surface)
        return;
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
            fprintf(stderr,
                    "canopy: terminal-activity tab=%llu focus=%d app=%d key=%d responder=%d "
                    "presented=%d visible=%d\n",
                    (unsigned long long)self.tab, gate.focused, state.app_active, state.window_key,
                    state.responder, state.presented, state.visible);
        }
    }
}
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self syncSize];
}
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self syncSize];
}
- (void)syncSize {
    if (!self.surface)
        return;
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
    if (!self.surface || self.sidebarOverlay)
        return;
    ghostty_input_key_s key = {0};
    key.action = action;
    key.keycode = event.keyCode;
    key.mods = mods(event.modifierFlags);
    key.consumed_mods = mods((self.keyEvent ? self.translationFlags : event.modifierFlags) &
                             ~(NSEventModifierFlagControl | NSEventModifierFlagCommand));
    // Ghostty encodes controls itself (including Ctrl+C and Ctrl+Enter).
    key.text = text.length && [text characterAtIndex:0] >= 0x20 ? text.UTF8String : NULL;
    NSString *unshifted = [event charactersByApplyingModifiers:0];
    if (unshifted.length) {
        unichar first = [unshifted characterAtIndex:0];
        key.unshifted_codepoint =
            CFStringIsSurrogateHighCharacter(first) && unshifted.length > 1
                ? CFStringGetLongCharacterForSurrogatePair(first, [unshifted characterAtIndex:1])
                : first;
    }
    key.composing = self.hasMarkedText;
    ghostty_surface_key(self.surface, key);
    self.keySent = YES;
}
- (void)keyDown:(NSEvent *)event {
    if (self.sidebarOverlay) {
        if (event.keyCode == 53)
            [self.host queue:self.tab kind:CANOPY_GHOSTTY_DISMISS_SIDEBAR code:0];
        return;
    }
    self.keyEvent = event;
    self.keySent = NO;
    ghostty_input_mods_e translated =
        self.surface ? ghostty_surface_key_translation_mods(self.surface, mods(event.modifierFlags))
                     : mods(event.modifierFlags);
    NSEventModifierFlags flags = event.modifierFlags;
    const NSEventModifierFlags nativeFlags[] = {
        NSEventModifierFlagShift, NSEventModifierFlagControl, NSEventModifierFlagOption,
        NSEventModifierFlagCommand};
    const unsigned ghosttyFlags[] = {GHOSTTY_MODS_SHIFT, GHOSTTY_MODS_CTRL, GHOSTTY_MODS_ALT,
                                     GHOSTTY_MODS_SUPER};
    for (int i = 0; i < 4; i++) {
        if (translated & ghosttyFlags[i])
            flags |= nativeFlags[i];
        else
            flags &= ~nativeFlags[i];
    }
    self.translationFlags = flags;
    NSEvent *translation = event;
    if (flags != event.modifierFlags)
        translation =
            [NSEvent keyEventWithType:event.type
                                   location:event.locationInWindow
                              modifierFlags:flags
                                  timestamp:event.timestamp
                               windowNumber:event.windowNumber
                                    context:nil
                                 characters:[event charactersByApplyingModifiers:flags] ?: @""
                charactersIgnoringModifiers:event.charactersIgnoringModifiers ?: @""
                                  isARepeat:event.isARepeat
                                    keyCode:event.keyCode]
                ?: event;
    [self interpretKeyEvents:@[ translation ]];
    if (!self.keySent && !self.hasMarkedText)
        [self sendKey:event
                 text:nil
               action:event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS];
    self.keyEvent = nil;
}
- (void)keyUp:(NSEvent *)event {
    [self sendKey:event text:nil action:GHOSTTY_ACTION_RELEASE];
}
- (void)doCommandBySelector:(SEL)selector {
    if (self.keyEvent)
        [self sendKey:self.keyEvent text:nil action:GHOSTTY_ACTION_PRESS];
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (!self.surface || self.window.firstResponder != self)
        return NO;
    ghostty_input_key_s key = {0};
    key.action = GHOSTTY_ACTION_PRESS;
    key.keycode = event.keyCode;
    key.mods = mods(event.modifierFlags);
    if (!ghostty_surface_key_is_binding(self.surface, key, NULL))
        return NO;
    ghostty_surface_key(self.surface, key);
    return YES;
}
- (void)insertText:(id)value replacementRange:(NSRange)range {
    if (self.sidebarOverlay)
        return;
    NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] : value;
    BOOL composed = self.hasMarkedText;
    [self unmarkText];
    if (!self.surface)
        return;
    if (self.keyEvent && !composed)
        [self sendKey:self.keyEvent
                 text:text
               action:self.keyEvent.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS];
    else {
        ghostty_surface_text(self.surface, text.UTF8String,
                             [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        self.keySent = YES;
    }
}
- (void)setMarkedText:(id)value
        selectedRange:(NSRange)selected
     replacementRange:(NSRange)replacement {
    self.marked = [value isKindOfClass:NSAttributedString.class]
                      ? [value mutableCopy]
                      : [[NSMutableAttributedString alloc] initWithString:value];
    if (self.surface)
        ghostty_surface_preedit(
            self.surface, self.marked.string.UTF8String,
            [self.marked.string lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
}
- (void)unmarkText {
    self.marked = nil;
    if (self.surface)
        ghostty_surface_preedit(self.surface, NULL, 0);
}
- (BOOL)hasMarkedText {
    return self.marked.length > 0;
}
- (NSRange)markedRange {
    return self.hasMarkedText ? NSMakeRange(0, self.marked.length) : NSMakeRange(NSNotFound, 0);
}
- (NSRange)selectedRange {
    return NSMakeRange(NSNotFound, 0);
}
- (NSArray *)validAttributesForMarkedText {
    return @[];
}
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                                actualRange:(NSRangePointer)actual {
    return nil;
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    return NSNotFound;
}
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
    double x = 0, y = 0, w = 1, h = 1;
    if (self.surface)
        ghostty_surface_ime_point(self.surface, &x, &y, &w, &h);
    return [self.window convertRectToScreen:[self convertRect:NSMakeRect(x, y, w, h) toView:nil]];
}
- (void)copy:(id)sender {
    if (self.surface)
        ghostty_surface_binding_action(self.surface, "copy_to_clipboard", 17);
}
- (void)paste:(id)sender {
    if (self.surface && !self.sidebarOverlay)
        ghostty_surface_binding_action(self.surface, "paste_from_clipboard", 20);
}
- (void)mouseMoved:(NSEvent *)event {
    if (self.sidebarOverlay)
        return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (self.surface)
        ghostty_surface_mouse_pos(self.surface, p.x, p.y, mods(event.modifierFlags));
}
- (void)sendMouseButton:(ghostty_input_mouse_button_e)button
                  state:(ghostty_input_mouse_state_e)state
                  event:(NSEvent *)event {
    bool suppress = self.suppressMouseUp;
    CanopyMouseDecision decision = CanopyTerminalMouseInput(
        self.sidebarOverlay, button == GHOSTTY_MOUSE_LEFT, state == GHOSTTY_MOUSE_PRESS, &suppress);
    self.suppressMouseUp = suppress;
    if (decision == CANOPY_MOUSE_DISMISS_SIDEBAR) {
        [self.host queue:self.tab kind:CANOPY_GHOSTTY_DISMISS_SIDEBAR code:0];
        return;
    }
    if (decision == CANOPY_MOUSE_BLOCK)
        return;
    if (button == GHOSTTY_MOUSE_LEFT && state == GHOSTTY_MOUSE_PRESS)
        [self.window makeFirstResponder:self];
    [self mouseMoved:event];
    if (self.surface)
        ghostty_surface_mouse_button(self.surface, state, button, mods(event.modifierFlags));
}
- (void)mouseDown:(NSEvent *)event {
    [self sendMouseButton:GHOSTTY_MOUSE_LEFT state:GHOSTTY_MOUSE_PRESS event:event];
}
- (void)mouseUp:(NSEvent *)event {
    [self sendMouseButton:GHOSTTY_MOUSE_LEFT state:GHOSTTY_MOUSE_RELEASE event:event];
}
- (void)mouseDragged:(NSEvent *)event {
    [self mouseMoved:event];
}
- (void)rightMouseDown:(NSEvent *)event {
    [self sendMouseButton:GHOSTTY_MOUSE_RIGHT state:GHOSTTY_MOUSE_PRESS event:event];
}
- (void)rightMouseUp:(NSEvent *)event {
    [self sendMouseButton:GHOSTTY_MOUSE_RIGHT state:GHOSTTY_MOUSE_RELEASE event:event];
}
- (void)rightMouseDragged:(NSEvent *)event {
    [self mouseMoved:event];
}
- (void)otherMouseDown:(NSEvent *)event {
    [self sendMouseButton:GHOSTTY_MOUSE_MIDDLE state:GHOSTTY_MOUSE_PRESS event:event];
}
- (void)otherMouseUp:(NSEvent *)event {
    [self sendMouseButton:GHOSTTY_MOUSE_MIDDLE state:GHOSTTY_MOUSE_RELEASE event:event];
}
- (void)otherMouseDragged:(NSEvent *)event {
    [self mouseMoved:event];
}
- (void)mouseExited:(NSEvent *)event {
    if (self.surface)
        ghostty_surface_mouse_pos(self.surface, -1, -1, mods(event.modifierFlags));
}
- (void)scrollWheel:(NSEvent *)event {
    if (self.sidebarOverlay)
        return;
    unsigned momentum = GHOSTTY_MOUSE_MOMENTUM_NONE;
    switch (event.momentumPhase) {
    case NSEventPhaseBegan:
        momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN;
        break;
    case NSEventPhaseStationary:
        momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY;
        break;
    case NSEventPhaseChanged:
        momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED;
        break;
    case NSEventPhaseEnded:
        momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED;
        break;
    case NSEventPhaseCancelled:
        momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED;
        break;
    case NSEventPhaseMayBegin:
        momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN;
        break;
    default:
        break;
    }
    double factor = event.hasPreciseScrollingDeltas ? 2 : 1;
    if (self.surface)
        ghostty_surface_mouse_scroll(self.surface, event.scrollingDeltaX * factor,
                                     event.scrollingDeltaY * factor,
                                     (momentum << 1) | (event.hasPreciseScrollingDeltas ? 1 : 0));
}
@end
