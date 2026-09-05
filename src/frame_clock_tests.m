#import <AppKit/AppKit.h>
#include <assert.h>
#include <stdio.h>
#include "native_sdk_frame_clock.h"
#include "native_sdk_raster_translation.h"

int main(void) {
    @autoreleasepool {
        assert(NativeSdkCanvasFrameIntervalNs(0) == 16666666);
        assert(NativeSdkCanvasFrameIntervalNs(60) == 16666666);
        assert(NativeSdkCanvasFrameIntervalNs(120) == 8333333);
        assert(NativeSdkCanvasFrameIntervalNs(144) == 6944444);
        assert(NativeSdkCanvasFrameIntervalNs(165) == 6060606);
        assert(NativeSdkCanvasFrameIntervalNs(240) == 4166666);
        NSDictionary *original = @{ @"kind": @"draw_text", @"text": @"status", @"opacity": @1,
            @"transform": @[@1,@0,@0,@1,@0,@8], @"bounds": @[@20,@28,@100,@20], @"clip": @[@0,@8,@300,@200] };
        NSMutableDictionary *moved = [original mutableCopy];
        moved[@"transform"] = @[@1,@0,@0,@1,@0,@7.75];
        moved[@"bounds"] = @[@20,@27.75,@100,@20];
        moved[@"clip"] = @[@0,@7.75,@300,@200];
        NSPoint delta = NSZeroPoint;
        NSRect raster = NSMakeRect(19, 27, 102, 22);
        assert(NativeSdkRasterTranslationReuse(original, moved, raster, 2, 800, 600, &delta));
        assert(delta.x == 0 && delta.y == -.25);
        moved[@"text"] = @"changed";
        assert(!NativeSdkRasterTranslationReuse(original, moved, raster, 2, 800, 600, NULL));
        moved[@"text"] = @"status";
        moved[@"opacity"] = @0.5;
        assert(!NativeSdkRasterTranslationReuse(original, moved, raster, 2, 800, 600, NULL));
        moved[@"opacity"] = @1;
        moved[@"clip"] = original[@"clip"];
        assert(NativeSdkRasterTranslationReuse(original, moved, raster, 2, 800, 600, NULL));
        NSMutableDictionary *cropped = [original mutableCopy];
        cropped[@"clip"] = @[@20,@28,@100,@20];
        moved[@"clip"] = cropped[@"clip"];
        assert(!NativeSdkRasterTranslationReuse(cropped, moved, raster, 2, 800, 600, NULL));
        moved[@"clip"] = @[@0,@7.75,@300,@200];
        assert(!NativeSdkRasterTranslationReuse(original, moved, NSMakeRect(0, 27, 102, 22), 2, 800, 600, NULL));
        [moved removeObjectForKey:@"transform"];
        assert(!NativeSdkRasterTranslationReuse(original, moved, raster, 2, 800, 600, NULL));

        // AppKit registers this mode on the UI loop. Exercise the same nested
        // mode without creating a window or touching the user's application.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), (__bridge CFStringRef)NSEventTrackingRunLoopMode);
        __block int frames = 0;
        __block int cancelledFrames = 0;
        NSTimer *cancelled = NativeSdkScheduleCanvasFrameTimer(.001, ^(NSTimer *timer) { cancelledFrames++; });
        [cancelled invalidate];
        NSTimer *frame = NativeSdkScheduleCanvasFrameTimer(.001, ^(NSTimer *timer) { frames++; });
        assert(frames == 0); // Never re-enter the runtime synchronously.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while (!frames && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop mainRunLoop] runMode:NSEventTrackingRunLoopMode beforeDate:deadline];
        }
        assert(frames == 1);
        assert(cancelledFrames == 0);
        assert(!frame.valid);
        puts("Canvas clock: tracking-mode delivery, cancellation and one-shot checks passed");
    }
    return 0;
}
