// App-specific toolbar density, applied once after canvas installation.
#import <AppKit/AppKit.h>

void canopy_use_compact_titlebar(void) {
    for (NSWindow *window in NSApp.windows) {
        // Only the empty geometry toolbar created for Canopy's hidden-inset
        // shell; leave panels, sheets and other system windows untouched.
        if (![window.toolbar.identifier isEqualToString:@"native-sdk-tall-titlebar"]) continue;
        if (window.toolbarStyle != NSWindowToolbarStyleUnifiedCompact) {
            window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
        }
    }
}
