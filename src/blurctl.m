#import <Foundation/Foundation.h>
#import <notify.h>

void printUsage() {
    puts("Usage: blurctl [command] [options]\n"
         "\nCommands:"
         "\n  on                    Enable blur tweak"
         "\n  off                   Disable blur tweak"
         "\n  toggle                Toggle blur tweak"
         "\n  status                Show current settings"
         "\n\nOptions:"
         "\n  --titlebar            Toggle transparent titlebar"
         "\n  --vibrancy            Toggle vibrancy effects"
         "\n  --emphasize           Toggle emphasis for focused windows"
         "\n  --intensity <0-100>   Set blur intensity (0-100)"
         "\n  --help, -h            Show this help message"
         "\n\nExamples:"
         "\n  blurctl on            Enable all blur effects"
         "\n  blurctl off           Disable all blur effects"
         "\n  blurctl toggle        Toggle blur on/off"
         "\n  blurctl --titlebar    Toggle transparent titlebars"
         "\n  blurctl --emphasize   Toggle emphasis for focused windows"
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
        
        if ([command isEqualToString:@"on"]) {
            notify_post("com.blur.tweak.enable");
            printf("Blur tweak enabled\n");
        } else if ([command isEqualToString:@"off"]) {
            notify_post("com.blur.tweak.disable");
            printf("Blur tweak disabled\n");
        } else if ([command isEqualToString:@"toggle"]) {
            notify_post("com.blur.tweak.toggle");
            printf("Blur tweak toggled\n");
        } else if ([command isEqualToString:@"status"]) {
            printf("Blur Tweak Status:\n");
            printf("  Use the tweak to check current settings\n");
            printf("  (Status querying not yet implemented)\n");
        } else if ([command isEqualToString:@"--titlebar"]) {
            notify_post("com.blur.tweak.titlebar");
            printf("Transparent titlebar toggled\n");
        } else if ([command isEqualToString:@"--vibrancy"]) {
            notify_post("com.blur.tweak.vibrancy");
            printf("Vibrancy toggled\n");
        } else if ([command isEqualToString:@"--emphasize"]) {
            notify_post("com.blur.tweak.emphasize");
            printf("Window emphasis toggled\n");
        } else if ([command isEqualToString:@"--intensity"]) {
            if (argc > 2) {
                int intensity = atoi(argv[2]);
                if (intensity >= 0 && intensity <= 100) {
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
