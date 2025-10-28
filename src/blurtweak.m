// Needed for BOOL definition
#import <objc/objc.h>
#ifdef __cplusplus
extern "C" {
#endif
int AddGlassEffectView(unsigned char *buffer, BOOL opaque);
void ConfigureGlassView(int viewId, double cornerRadius, const char* tintHex);
#ifdef __cplusplus
}
#endif
@import Foundation;
@import AppKit;
@import QuartzCore;
@import CoreImage;
#import <objc/runtime.h>
#import "./ZKSwizzle.h"
#import <notify.h>

/**
 * Finder Blur Tweak
 * 
 * Transparent blurred windows for Finder only.
 * Desktop wallpaper visible through blur, content opaque and readable.
 */

#pragma mark - Configuration

// Global state
static BOOL enableBlurTweak = YES;
static BOOL enableTransparentTitlebar = YES;
static CGFloat blurIntensity = 0.85; // 0.0 to 1.0

// Cache for glass effect view IDs
static NSMutableDictionary<NSNumber *, NSNumber *> *windowGlassViewIds = nil;

#pragma mark - Helper Functions

// Check if we're running in Finder
static inline BOOL isFinderProcess(void) {
    static dispatch_once_t onceToken;
    static BOOL isFinder = NO;
    dispatch_once(&onceToken, ^{
        NSString *processName = [[NSProcessInfo processInfo] processName];
        isFinder = [processName isEqualToString:@"Finder"];
        NSLog(@"[BlurTweak] Process: %@, Finder-only mode: %@", processName, isFinder ? @"YES" : @"NO");
    });
    return isFinder;
}

// Check if a window should have blur effects applied
static inline BOOL shouldApplyBlurEffects(NSWindow *window) {
    if (!window || !enableBlurTweak) return NO;
    
    // Only apply to Finder
    if (!isFinderProcess()) return NO;
    
    NSWindowStyleMask mask = window.styleMask;
    
    // Exclude desktop windows (level < 0)
    if (window.level < 0) return NO;
    
    // Exclude high-level windows (menus, popovers, tooltips are at level > 0)
    if (window.level > NSNormalWindowLevel) return NO;
    
    // Exclude NSPanel subclasses (alerts, dialogs, popovers, menus)
    if ([window isKindOfClass:NSClassFromString(@"NSPanel")]) return NO;
    
    // Exclude NSMenu windows
    if ([window isKindOfClass:NSClassFromString(@"NSMenuWindow")]) return NO;
    
    // Exclude utility and HUD windows
    if (mask & (NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskHUDWindow)) return NO;
    
    // Exclude modal sheets
    if (window.sheet || window.sheetParent) return NO;
    
    // Exclude borderless windows (often used for menus/popovers)
    if (!(mask & NSWindowStyleMaskTitled)) return NO;
    
    // Must have content view and be visible
    if (!window.contentView || !window.isVisible) return NO;
    
    return YES;
}


// Get or create glass effect view for a window using the private API
static int getGlassViewIdForWindow(NSWindow *window) {
    if (!windowGlassViewIds) {
        windowGlassViewIds = [NSMutableDictionary dictionary];
    }
    NSNumber *windowKey = @((NSUInteger)window);
    NSNumber *glassId = windowGlassViewIds[windowKey];
    if (!glassId && window.contentView) {
        // Use the private API: AddGlassEffectView
        int newId = -1;
        void *viewPtr = (__bridge void *)window.contentView;
        newId = AddGlassEffectView((unsigned char *)&viewPtr, NO);
        if (newId >= 0) {
            glassId = @(newId);
            windowGlassViewIds[windowKey] = glassId;
        }
    }
    return glassId ? glassId.intValue : -1;
}

// Apply glass effect to a window using the private API
static void applyGlassEffectToWindow(NSWindow *window) {
    if (!shouldApplyBlurEffects(window)) return;
    int glassId = getGlassViewIdForWindow(window);
    if (glassId < 0) return;
    // Make window background transparent
    window.backgroundColor = [NSColor clearColor];
    window.opaque = NO;
    window.hasShadow = YES;
    // Configure the glass view (corner radius, tint)
    ConfigureGlassView(glassId, 8.0, NULL); // Example: 8px radius, no tint
    // Transparent titlebar
    if (enableTransparentTitlebar) {
        window.titlebarAppearsTransparent = YES;
        if (window.styleMask & NSWindowStyleMaskTitled) {
            window.styleMask |= NSWindowStyleMaskFullSizeContentView;
        }
    }
}

// Remove glass effect from a window
static void removeGlassEffectFromWindow(NSWindow *window) {
    if (!windowGlassViewIds) return;
    NSNumber *windowKey = @((NSUInteger)window);
    NSNumber *glassId = windowGlassViewIds[windowKey];
    if (glassId) {
        // No direct remove API, but re-adding the contentView or refreshing may be needed
        // For now, just remove the mapping
        [windowGlassViewIds removeObjectForKey:windowKey];
    }
    // Restore original window appearance
    window.backgroundColor = [NSColor windowBackgroundColor];
    window.opaque = YES;
    window.titlebarAppearsTransparent = NO;
}

// Update all existing windows
static void updateAllWindows(BOOL enable) {
    NSArray<NSWindow *> *windows = [NSApplication sharedApplication].windows;
    for (NSWindow *window in windows) {
        if (enable) {
            applyGlassEffectToWindow(window);
        } else {
            removeGlassEffectFromWindow(window);
        }
    }
}

// Update intensity on all active glass views
static void updateIntensityOnAllViews(void) {
    if (!windowGlassViewIds) return;
    for (NSNumber *windowKey in windowGlassViewIds) {
        NSNumber *glassId = windowGlassViewIds[windowKey];
        if (glassId) {
            // No direct alpha API, but we can try to set tint or other property if needed
            // For now, just call ConfigureGlassView with updated parameters
            ConfigureGlassView(glassId.intValue, 8.0, NULL);
        }
    }
}

#pragma mark - Darwin Notification Handlers

static void registerNotificationHandlers(void) {
    int token;
    
    // Enable/disable/toggle notifications
    notify_register_dispatch("com.blur.tweak.enable", &token,
                             dispatch_get_main_queue(), ^(int t) {
        (void)t;
        enableBlurTweak = YES;
        updateAllWindows(YES);
    });
    
    notify_register_dispatch("com.blur.tweak.disable", &token,
                             dispatch_get_main_queue(), ^(int t) {
        (void)t;
        enableBlurTweak = NO;
        updateAllWindows(NO);
    });
    
    notify_register_dispatch("com.blur.tweak.toggle", &token,
                             dispatch_get_main_queue(), ^(int t) {
        (void)t;
        enableBlurTweak = !enableBlurTweak;
        updateAllWindows(enableBlurTweak);
    });
    
    // Intensity notification
    notify_register_dispatch("com.blur.tweak.intensity", &token,
                             dispatch_get_main_queue(), ^(int t) {
        (void)t;
        uint64_t state;
        notify_get_state(t, &state);
        CGFloat newIntensity = (CGFloat)state / 100.0;  // Intensity sent as 0-100
        if (newIntensity >= 0.0 && newIntensity <= 1.0) {
            blurIntensity = newIntensity;
            updateIntensityOnAllViews();
        }
    });
}

#pragma mark - Swizzled NSWindow

ZKSwizzleInterface(BlurTweak_NSWindow, NSWindow, NSWindow)
@implementation BlurTweak_NSWindow

- (id)initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backingStoreType defer:(BOOL)flag {
    self = [super initWithContentRect:contentRect styleMask:style backing:backingStoreType defer:flag];
    if (self && enableBlurTweak) {
        dispatch_async(dispatch_get_main_queue(), ^{
            applyGlassEffectToWindow((NSWindow *)self);
        });
    }
    return self;
}

- (void)setFrame:(NSRect)frameRect display:(BOOL)flag {
    ZKOrig(void, frameRect, flag);
    
    if (enableBlurTweak && shouldApplyBlurEffects(self)) {
        // No direct frame update needed for glass effect, handled by autoresizing
    }
}

- (void)orderFront:(id)sender {
    ZKOrig(void, sender);
    if (enableBlurTweak) {
        applyGlassEffectToWindow(self);
    }
}

- (void)close {
    if (enableBlurTweak) {
        removeGlassEffectFromWindow(self);
    }
    ZKOrig(void);
}

@end

#pragma mark - Constructor

__attribute__((constructor))
static void initializeBlurTweak(void) {
    @autoreleasepool {
        NSLog(@"[BlurTweak] Initializing Finder-only blur tweak");
        
        // Only proceed if running in Finder
        if (!isFinderProcess()) {
            NSLog(@"[BlurTweak] Not running in Finder, skipping initialization");
            return;
        }
        
        // Register notification handlers
        registerNotificationHandlers();
        
        // Apply to existing windows after short delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), 
                      dispatch_get_main_queue(), ^{
            updateAllWindows(YES);
        });
        
        NSLog(@"[BlurTweak] Finder blur tweak initialized");
    }
}
