#import <Foundation/Foundation.h>
#import <notify.h>

void printUsage() {
    puts("Usage: blurctl [command] [options]\n"
         "\nCommands:"
         "\n  on                    Enable blur tweak"
         "\n  off                   Disable blur tweak"
         "\n  toggle                Toggle blur tweak"
         "\n  nav-toggle            Toggle navigation area blur"
         "\n  status                Show current settings"
         "\n\nOptions:"
         "\n  --intensity <0-100>   Set blur intensity (0-100)"
         "\n  --help, -h            Show this help message"
         "\n\nExamples:"
         "\n  blurctl on            Enable all blur effects"
         "\n  blurctl off           Disable all blur effects"
         "\n  blurctl toggle        Toggle blur on/off"
         "\n  blurctl nav-toggle    Toggle navigation area blur"
         "\n  blurctl --intensity 75  Set blur intensity to 75%");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            printUsage();
            return 1;
        }
        
        NSString *command = [NSString stringWithUTF8String:argv[1]];
        
        if ([command isEqualToString:@"--help"] || [command isEqualToString:@"-h"]) {
            printUsage();
            return 0;
        }
        
        NSString *prefsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.blur.tweak.plist"];
        NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:prefsPath];
        if (!prefs) prefs = [NSMutableDictionary dictionary];
        
        if ([command isEqualToString:@"on"]) {
            prefs[@"enabled"] = @YES;
            [prefs writeToFile:prefsPath atomically:YES];
            notify_post("com.blur.tweak.enable");
            printf("Blur tweak enabled\n");
        } else if ([command isEqualToString:@"off"]) {
            prefs[@"enabled"] = @NO;
            [prefs writeToFile:prefsPath atomically:YES];
            notify_post("com.blur.tweak.disable");
            printf("Blur tweak disabled\n");
        } else if ([command isEqualToString:@"toggle"]) {
            BOOL wasEnabled = [prefs[@"enabled"] boolValue];
            BOOL nowEnabled = !wasEnabled;
            prefs[@"enabled"] = @(nowEnabled);
            [prefs writeToFile:prefsPath atomically:YES];
            notify_post("com.blur.tweak.toggle");
            printf("Blur tweak toggled\n");
        } else if ([command isEqualToString:@"nav-toggle"]) {
            BOOL wasEnabled = [prefs[@"navigationBlur"] boolValue];
            BOOL nowEnabled = !wasEnabled;
            prefs[@"navigationBlur"] = @(nowEnabled);
            [prefs writeToFile:prefsPath atomically:YES];
            notify_post("com.blur.tweak.navigation.toggle");
            printf("Navigation blur toggled: %s\n", nowEnabled ? "ON" : "OFF");
        } else if ([command isEqualToString:@"status"]) {
            NSDictionary *currentPrefs = [NSDictionary dictionaryWithContentsOfFile:prefsPath];
            BOOL enabled = [currentPrefs[@"enabled"] boolValue];
            BOOL navBlur = [currentPrefs[@"navigationBlur"] boolValue];
            int intensity = [currentPrefs[@"intensity"] intValue];
            printf("Blur Tweak Status:\n");
            printf("  Enabled: %s\n", enabled ? "Yes" : "No");
            printf("  Navigation Blur: %s\n", navBlur ? "Yes" : "No");
            printf("  Intensity: %d%%\n", intensity);
        } else if ([command isEqualToString:@"--intensity"]) {
            if (argc > 2) {
                int intensity = atoi(argv[2]);
                if (intensity >= 0 && intensity <= 100) {
                    prefs[@"intensity"] = @(intensity);
                    [prefs writeToFile:prefsPath atomically:YES];
                    int token = 0;
                    if (notify_register_check("com.blur.tweak.intensity", &token) == NOTIFY_STATUS_OK) {
                        notify_set_state(token, intensity);
                        notify_post("com.blur.tweak.intensity");
                        notify_cancel(token);
                        printf("Blur intensity set to %d%%\n", intensity);
                    }
                } else {
                    printf("Error: Intensity must be between 0 and 100\n");
                    return 1;
                }
            } else {
                printf("Error: --intensity requires a value (0-100)\n");
                return 1;
            }
        } else {
            printf("Unknown command: %s\n", [command UTF8String]);
            printUsage();
            return 1;
        }
    }
    return 0;
}
