// Private AppKit implementation types. Public ABI remains ghostty_bridge.h.
#pragma once
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include "ghostty.h"
#include "ghostty_bridge.h"
#include "ghostty_activity.h"
#include "ghostty_input.h"

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
