// The host app. It only exists to carry the two Quick Look extensions: macOS starts those on
// its own whenever Finder needs a thumbnail or a preview, so this app never has to run.
// Opening it shows a short confirmation.

#import <Cocoa/Cocoa.h>

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];

        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"BRAW Preview is installed";
        alert.informativeText =
            @"Finder now shows thumbnails for Blackmagic RAW (.braw) clips, and the Space bar plays them in Quick Look.\n\n"
            @"This app does not need to run: macOS starts the extensions by itself whenever Finder needs them, also after a restart.\n\n"
            @"If thumbnails don't show up: System Settings → General → Login Items & Extensions → Quick Look.";
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Extension Settings"];

        if ([alert runModal] == NSAlertSecondButtonReturn) {
            NSURL *settings = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.ExtensionsPreferences"];
            [[NSWorkspace sharedWorkspace] openURL:settings];
        }
    }
    return 0;
}
