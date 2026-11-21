// The host app. It only exists to carry the two Quick Look extensions: macOS starts those on
// its own whenever Finder needs a thumbnail or a preview, so this app never has to run.
// Opening it shows a short confirmation.

#import <Cocoa/Cocoa.h>

static BOOL PrefersHungarian(void)
{
    NSString *language = NSLocale.preferredLanguages.firstObject ?: @"";
    return [language hasPrefix:@"hu"];
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];

        const BOOL hu = PrefersHungarian();
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = hu ? @"A BRAW Preview telepítve van" : @"BRAW Preview is installed";
        alert.informativeText = hu
            ? @"A Finder mostantól bélyegképet és Gyorsnézet-előnézetet (szóköz) mutat a Blackmagic RAW (.braw) klipekhez.\n\n"
              @"Ezt az appot nem kell futtatni: a macOS magától elindítja a bővítményt, amikor a Findernek szüksége van rá, újraindítás után is.\n\n"
              @"Ha nem jelennek meg a bélyegképek: Rendszerbeállítások → Általános → Bejelentkezési elemek és bővítmények → Gyorsnézet."
            : @"Finder now shows thumbnails and Quick Look previews (Space bar) for Blackmagic RAW (.braw) clips.\n\n"
              @"This app does not need to run: macOS starts the extension by itself whenever Finder needs it, also after a restart.\n\n"
              @"If thumbnails don't show up: System Settings → General → Login Items & Extensions → Quick Look.";
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:hu ? @"Bővítménybeállítások" : @"Extension Settings"];

        if ([alert runModal] == NSAlertSecondButtonReturn) {
            NSURL *settings = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.ExtensionsPreferences"];
            [[NSWorkspace sharedWorkspace] openURL:settings];
        }
    }
    return 0;
}
