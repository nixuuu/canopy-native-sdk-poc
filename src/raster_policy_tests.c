#include <assert.h>
#include <stdio.h>
#include "native_sdk_raster_policy.h"

int main(void) {
    assert(NativeSdkRasterTranslationCacheable(1, 0, 0, 1, 0, 0));
    assert(NativeSdkRasterTranslationCacheable(1, 0, 0, 1, 239.75, -400));
    assert(NativeSdkRasterTranslationCacheable(1.000000119, 0, 0, .99999994, .000061, .000031));
    assert(!NativeSdkRasterTranslationCacheable(.625, 0, 0, .625, 12, 13));
    assert(!NativeSdkRasterTranslationCacheable(1.01, 0, 0, 1.01, 12, 13));
    assert(!NativeSdkRasterTranslationCacheable(0, 1, -1, 0, 12, 13));
    assert(!NativeSdkRasterTranslationCacheable(1, .01, 0, 1, 12, 13));
    assert(!NativeSdkRasterTranslationCacheable(-1, 0, 0, 1, 12, 13));
    assert(!NativeSdkRasterTranslationCacheable(NAN, 0, 0, 1, 0, 0));
    assert(!NativeSdkRasterTranslationCacheable(1, 0, 0, 1, INFINITY, 0));
    assert(NativeSdkCanvasSizeMatches(1000, 800, 1000, 800));
    assert(!NativeSdkCanvasSizeMatches(1000, 800, 1000, 801));
    assert(!NativeSdkCanvasSizeMatches(1000, 800, 1001, 800));
    puts("Raster cache and presentation policy: 13 checks passed");
    return 0;
}
