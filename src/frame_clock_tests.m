#import <AppKit/AppKit.h>
#include <assert.h>
#include <stdio.h>
#include "native_sdk_frame_clock.h"

int main(void) {
    @autoreleasepool {
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
