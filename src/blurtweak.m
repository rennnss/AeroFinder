@import Foundation;
@import AppKit;
@import QuartzCore;
@import CoreImage;
#import <objc/runtime.h>
#import "./ZKSwizzle.h"
#import <notify.h>

/**
 * Finder Blur Tweak - Liquid Glass Implementation
 * 
 * Proper Liquid Glass implementation using NSGlassEffectView at BOTTOM-MOST LAYER:
 * 
 * ARCHITECTURE:
 * - NSGlassEffectView with Style.clear at ABSOLUTE BOTTOM-MOST LAYER
 * - Positioned at index 0 in subviews array (first to render = back layer)
 * - zPosition set to -1000 to guarantee bottom positioning
 * - Continuous enforcement ensures glass stays at bottom even if views are added
 * - Window made transparent (opaque=NO) to allow glass to blur desktop
 * - All Finder UI elements made transparent to work with glass material
 * - Content remains visible and vibrant on top of bottom glass layer
 * - NO fallback to NSVisualEffectView (requires macOS 26.0+)
 * - Finder-only injection (isolated from other applications)
 * 
 * CRITICAL POSITIONING:
 * - Glass view ALWAYS at subviews[0] = absolute bottom of render stack
 * - layer.zPosition = -1000 for guaranteed depth ordering
 * - Continuous monitoring prevents Finder from pushing glass view up
 * - All Finder content renders ABOVE the glass background layer
 * 
 * IMPLEMENTATION DETAILS:
 * - NSGlassEffectView.Style.clear = maximum transparency + desktop blur
 * - Positioned using NSWindowBelow relativeTo:firstObject for bottom placement
 * - Corner radius masking (10pt for windows, 6pt for navigation elements)
 * - Automatic adaptation to light/dark appearance
 * - Fluid morphing and transitions between glass elements
 * 
 * LIQUID GLASS PROPERTIES (per Apple Documentation):
 * - Blurs content behind it (desktop wallpaper through window)
 * - Reflects color and light of surrounding content
 * - Reacts to touch and pointer interactions in real-time
 * - Combines optical properties of glass with fluidity
 * - Forms distinct functional layer for controls and navigation
 * - Adapts to accessibility settings (reduced transparency/motion)
 * 
 * SYSTEM REQUIREMENTS:
 * - macOS 26.0+ (Sequoia 16.0+) for NSGlassEffectView
 * - Finder-only (does not affect other applications)
 * 
 * @author rennnss
 * @version 5.1 - Bottom-Most Layer Implementation
 * @date 2025-11-09
 */

#pragma mark - Configuration

// Global state
static BOOL enableBlurTweak = YES;
static BOOL enableNavigationBlur = YES;
static BOOL liquidGlassAvailable = NO;

// Load persistent settings
static void loadPersistentSettings(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.blur.tweak.plist"]];
    if (prefs[@"enabled"]) enableBlurTweak = [prefs[@"enabled"] boolValue];
    if (prefs[@"navigationBlur"]) enableNavigationBlur = [prefs[@"navigationBlur"] boolValue];
}

// Caches for visual effect views
static NSMutableDictionary<NSNumber *, NSView *> *windowBlurViews = nil;  // Changed to NSView to support both types
static NSMutableDictionary<NSNumber *, NSView *> *navigationBlurViews = nil;
static NSMutableSet<NSView *> *trackedNavigationViews = nil;
static NSView *glassEffectContainer = nil;  // Container for Liquid Glass optimization

#pragma mark - Forward Declarations

static void applyNavigationBlurToWindow(NSWindow *window);
static void removeNavigationBlurFromWindow(NSWindow *window);
static void findNavigationViewsRecursive(NSView *view, NSMutableArray *results);
static void updateAllWindows(BOOL enable);
static void updateIntensityOnAllViews(void);
static void makeViewHierarchyTransparent(NSView *view, BOOL transparent);

#pragma mark - Helper Functions

// Check if we're running in Finder
#pragma mark - Finder Detection (Optimized)

/**
 * Check if current process is Finder
 * This ensures the tweak ONLY affects Finder and no other applications
 */
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

/**
 * Check if a class name is a Finder UI element that should be transparent
 * ONLY targets background/container views, NOT content elements like icons and text
 */
static inline BOOL isFinderUIElement(NSString *className) {
    if (!className) return NO;
    
    // ONLY target background/container elements
    // DO NOT target content elements (icons, text, cells, controllers)
    static NSSet<NSString *> *backgroundContainers = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        backgroundContainers = [NSSet setWithArray:@[
            @"TSidebarScrollView",        // Sidebar scroll background
            @"TSidebarView",              // Sidebar container background
            @"TSidebarOutlineView",       // Sidebar list background
            @"TSourceListView",           // Source list background
            @"TSplitView",                // Split view container
            @"TScrollView",               // Finder scroll view background
            @"TStatusBar",                // Status bar at bottom of window
            @"TToolbarView",              // Toolbar background
            @"TPathControlView"           // Path control background
        ]];
    });
    
    // Only match exact background containers
    return [backgroundContainers containsObject:className];
}

// Check if Liquid Glass (NSGlassEffectView) is available
static inline BOOL checkLiquidGlassAvailability(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        liquidGlassAvailable = (NSClassFromString(@"NSGlassEffectView") != nil);
        NSLog(@"[BlurTweak] Liquid Glass available: %@", liquidGlassAvailable ? @"YES" : @"NO");
    });
    return liquidGlassAvailable;
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

/**
 * Apply aggressive transparency to a Finder UI view
 * Centralized function to avoid code duplication
 */
static void makeFinderViewTransparent(NSView *view, NSString *className) {
    if (!view) return;
    
    // CRITICAL: DO NOT use wantsLayer = YES - it causes coordinate system flipping
    // Only use layer properties if the view already has a layer
    
    // Disable background drawing if supported
    if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
        @try {
            [(id)view setDrawsBackground:NO];
        } @catch (NSException *e) {}
    }
    
    // Force background color to clear
    if ([view respondsToSelector:@selector(setBackgroundColor:)]) {
        @try {
            [(id)view setBackgroundColor:[NSColor clearColor]];
        } @catch (NSException *e) {}
    }
    
    // If view already has a layer (without forcing it), make it transparent
    if (view.layer) {
        view.layer.opaque = NO;
        view.layer.backgroundColor = [[NSColor clearColor] CGColor];
    }
    
    NSLog(@"[BlurTweak] ✓ Made %@ transparent (preserved coordinate system)", className);
}

// Check if a view is a Finder navigation view (file list, browser, etc.)
static inline BOOL isNavigationView(NSView *view) {
    if (!view) return NO;
    
    // Check for common Finder navigation view classes
    NSString *className = NSStringFromClass([view class]);
    
    // NSBrowser - column view
    if ([view isKindOfClass:NSClassFromString(@"NSBrowser")]) return YES;
    
    // NSOutlineView - list view AND sidebar
    if ([view isKindOfClass:NSClassFromString(@"NSOutlineView")]) return YES;
    
    // NSTableView - table-based views
    if ([view isKindOfClass:NSClassFromString(@"NSTableView")]) return YES;
    
    // NSCollectionView - icon view, gallery view
    if ([view isKindOfClass:NSClassFromString(@"NSCollectionView")]) return YES;
    
    // NSSplitView - contains sidebar and main content
    if ([view isKindOfClass:[NSSplitView class]]) return YES;
    
    // Finder-specific private classes (may vary by macOS version)
    if ([className containsString:@"TBrowserView"] || 
        [className containsString:@"TDesktopView"] ||
        [className containsString:@"TIconView"] ||
        [className containsString:@"TListView"] ||
        [className containsString:@"TColumnView"] ||
        [className containsString:@"TSidebar"]) {
        return YES;
    }
    
    return NO;
}

// Find navigation views recursively in a view hierarchy
static void findNavigationViewsRecursive(NSView *view, NSMutableArray *results) {
    if (!view) return;
    
    if (isNavigationView(view)) {
        [results addObject:view];
    }
    
    for (NSView *subview in view.subviews) {
        findNavigationViewsRecursive(subview, results);
    }
}

// Get material based on current system appearance
static NSVisualEffectMaterial getMaterialForAppearance(BOOL isNavigationArea) {
    // Use appropriate material based on context
    // Materials automatically adapt to system appearance (light/dark)
    
    if (isNavigationArea) {
        // Navigation area uses ContentBackground for within-window blending
        return NSVisualEffectMaterialContentBackground;
    } else {
        // Window background uses UnderWindowBackground for desktop blending
        return NSVisualEffectMaterialUnderWindowBackground;
    }
}

// Apply corner radius and masking to a layer
static inline void applyCornerMasking(CALayer *layer, CGFloat radius) {
    layer.cornerRadius = radius;
    layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | 
                          kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    layer.masksToBounds = YES;
}

// Set glass view style to clear
static inline void setGlassStyleClear(NSView *glassView) {
    SEL styleSelector = NSSelectorFromString(@"setStyle:");
    if ([glassView respondsToSelector:styleSelector]) {
        NSInteger clearStyle = 0;
        NSMethodSignature *signature = [glassView methodSignatureForSelector:styleSelector];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setSelector:styleSelector];
        [invocation setTarget:glassView];
        [invocation setArgument:&clearStyle atIndex:2];
        [invocation invoke];
    }
}

// Get or create blur view for a window - FULL WINDOW COVERAGE (Liquid Glass ONLY)
static NSView *getBlurViewForWindow(NSWindow *window) {
    if (!windowBlurViews) windowBlurViews = [NSMutableDictionary dictionary];
    
    NSNumber *windowKey = @((NSUInteger)window);
    NSView *blurView = windowBlurViews[windowKey];
    
    if (!blurView && window.contentView) {
        if (!liquidGlassAvailable) {
            NSLog(@"[BlurTweak] ERROR: NSGlassEffectView not available (requires macOS 26.0+)");
            return nil;
        }
        
        Class glassClass = NSClassFromString(@"NSGlassEffectView");
        if (!glassClass) return nil;
        
        blurView = [[glassClass alloc] initWithFrame:window.contentView.bounds];
        setGlassStyleClear(blurView);
        
        blurView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        blurView.wantsLayer = YES;
        
        if (blurView.layer) {
            blurView.layer.opaque = NO;
            blurView.layer.backgroundColor = [[NSColor clearColor] CGColor];
            applyCornerMasking(blurView.layer, 10.0);
        }
        
        windowBlurViews[windowKey] = blurView;
        NSLog(@"[BlurTweak] Created NSGlassEffectView for window");
    }
    
    return blurView;
}

// Get or create navigation blur view - LIQUID GLASS ONLY
static NSView *getNavigationBlurView(NSView *navigationView) {
    if (!navigationBlurViews) navigationBlurViews = [NSMutableDictionary dictionary];
    if (!trackedNavigationViews) trackedNavigationViews = [NSMutableSet set];
    
    NSNumber *viewKey = @((NSUInteger)navigationView);
    NSView *navBlurView = navigationBlurViews[viewKey];
    
    if (!navBlurView && liquidGlassAvailable) {
        Class glassClass = NSClassFromString(@"NSGlassEffectView");
        if (!glassClass) return nil;
        
        navBlurView = [[glassClass alloc] initWithFrame:navigationView.bounds];
        setGlassStyleClear(navBlurView);
        
        navBlurView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        navBlurView.wantsLayer = YES;
        
        if (navBlurView.layer) {
            navBlurView.layer.opaque = NO;
            navBlurView.layer.backgroundColor = [[NSColor clearColor] CGColor];
            applyCornerMasking(navBlurView.layer, 6.0);
        }
        
        navigationBlurViews[viewKey] = navBlurView;
        [trackedNavigationViews addObject:navigationView];
    }
    
    return navBlurView;
}

// Apply blur effects to a window - LIQUID GLASS WITH PROPER EMBEDDING
static void applyBlurEffectsToWindow(NSWindow *window) {
    if (!shouldApplyBlurEffects(window)) return;
    
    // CRITICAL: Double-check - absolutely do NOT modify sheets, panels, or modal windows
    if (window.sheet || window.sheetParent || [window isKindOfClass:NSClassFromString(@"NSPanel")]) {
        return;
    }
    
    NSView *glassView = getBlurViewForWindow(window);
    if (!glassView) return;
    
    NSView *contentView = window.contentView;
    if (!contentView) return;
    
    // Make window transparent for glass effect
    window.backgroundColor = [NSColor clearColor];
    window.opaque = NO;
    window.hasShadow = YES;
    
    // DO NOT modify titlebar - removed all titlebar tweaks to prevent issues with sheets/dialogs
    
    BOOL glassAlreadyAdded = (glassView.superview != nil);
    
    if (!glassAlreadyAdded) {
        // Remove Finder's NSVisualEffectView
        for (NSView *subview in [contentView.subviews copy]) {
            if ([subview isKindOfClass:[NSVisualEffectView class]]) {
                [subview removeFromSuperview];
            }
        }
        
        makeViewHierarchyTransparent(contentView, YES);
        
        // Add glass to BOTTOM-MOST LAYER with corner extension
        glassView.frame = NSInsetRect(contentView.bounds, -2.0, -2.0);
        
        if (contentView.subviews.count > 0) {
            [contentView addSubview:glassView positioned:NSWindowBelow relativeTo:contentView.subviews.firstObject];
        } else {
            [contentView addSubview:glassView];
        }
        
        // Ensure bottom position
        if ([contentView.subviews indexOfObject:glassView] != 0) {
            [glassView removeFromSuperview];
            [contentView addSubview:glassView positioned:NSWindowBelow relativeTo:contentView.subviews.firstObject];
        }
        
        if (glassView.layer) {
            glassView.layer.zPosition = -1000.0;
            glassView.layer.opaque = NO;
            glassView.layer.backgroundColor = [[NSColor clearColor] CGColor];
            applyCornerMasking(glassView.layer, 10.0);
        }
        
        NSLog(@"[BlurTweak] ✓ Added NSGlassEffectView to BOTTOM-MOST LAYER");
    } else {
        glassView.frame = NSInsetRect(contentView.bounds, -2.0, -2.0);
        
        NSUInteger currentIndex = [contentView.subviews indexOfObject:glassView];
        if (currentIndex != 0 && contentView.subviews.count > 1) {
            [glassView removeFromSuperview];
            [contentView addSubview:glassView positioned:NSWindowBelow relativeTo:contentView.subviews.firstObject];
        }
        
        if (glassView.layer) {
            applyCornerMasking(glassView.layer, 10.0);
            glassView.layer.zPosition = -1000.0;
        }
    }
    
    // Continuous enforcement
    static NSMutableDictionary *windowTimers = nil;
    if (!windowTimers) windowTimers = [NSMutableDictionary dictionary];
    
    NSNumber *windowKey = @((NSUInteger)window);
    if (!windowTimers[windowKey]) {
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.016 repeats:YES block:^(NSTimer *t) { // ~60fps refresh rate
            if (!window || !window.isVisible) {
                [t invalidate];
                [windowTimers removeObjectForKey:windowKey];
                return;
            }
            
            window.backgroundColor = [NSColor clearColor];
            window.opaque = NO;
            
            NSView *cv = window.contentView;
            if (cv) {
                for (NSView *subview in [cv.subviews copy]) {
                    if ([subview isKindOfClass:[NSVisualEffectView class]]) {
                        [subview removeFromSuperview];
                    }
                }
                
                NSView *ourGlassView = getBlurViewForWindow(window);
                if (ourGlassView && ourGlassView.superview == cv) {
                    NSUInteger glassIndex = [cv.subviews indexOfObject:ourGlassView];
                    if (glassIndex != 0 && cv.subviews.count > 1) {
                        [ourGlassView removeFromSuperview];
                        [cv addSubview:ourGlassView positioned:NSWindowBelow relativeTo:cv.subviews.firstObject];
                        if (ourGlassView.layer) ourGlassView.layer.zPosition = -1000.0;
                    }
                }
            }
        }];
        windowTimers[windowKey] = timer;
    }
    
    if (enableNavigationBlur) {
        dispatch_async(dispatch_get_main_queue(), ^{
            applyNavigationBlurToWindow(window);
        });
    }
}

// Apply navigation-specific blur effects - LIQUID GLASS ONLY
static void applyNavigationBlurToWindow(NSWindow *window) {
    if (!enableNavigationBlur || !window.contentView) return;
    
    NSMutableArray *navigationViews = [NSMutableArray array];
    findNavigationViewsRecursive(window.contentView, navigationViews);
    
    for (NSView *navView in navigationViews) {
        // Skip if already has glass
        BOOL hasGlass = NO;
        for (NSView *subview in navView.subviews) {
            if ([subview isKindOfClass:NSClassFromString(@"NSGlassEffectView")]) {
                hasGlass = YES;
                break;
            }
        }
        if (hasGlass) continue;
        
        NSView *navGlassView = getNavigationBlurView(navView);
        if (!navGlassView || navGlassView.superview == navView) continue;
        
        // Make navigation view transparent
        if (navView.layer) {
            navView.layer.backgroundColor = [[NSColor clearColor] CGColor];
            navView.layer.opaque = NO;
        }
        
        if ([navView respondsToSelector:@selector(setBackgroundColor:)]) {
            @try { [(id)navView setBackgroundColor:[NSColor clearColor]]; } @catch (NSException *e) {}
        }
        
        if ([navView respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [(id)navView setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        
        // Add to bottom with corner extension
        navGlassView.frame = NSInsetRect(navView.bounds, -1.0, -1.0);
        
        if (navView.subviews.count > 0) {
            [navView addSubview:navGlassView positioned:NSWindowBelow relativeTo:navView.subviews.firstObject];
        } else {
            [navView addSubview:navGlassView];
        }
        
        if (navGlassView.layer) navGlassView.layer.zPosition = -1000.0;
        
        // Real-time enforcement for navigation views
        static NSMutableDictionary *navTimers = nil;
        if (!navTimers) navTimers = [NSMutableDictionary dictionary];
        
        NSNumber *navKey = @((NSUInteger)navView);
        if (!navTimers[navKey]) {
            NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.016 repeats:YES block:^(NSTimer *t) { // ~60fps
                if (!navView || !navView.window) {
                    [t invalidate];
                    [navTimers removeObjectForKey:navKey];
                    return;
                }
                
                // Keep navigation transparent
                if (navView.layer) {
                    navView.layer.backgroundColor = [[NSColor clearColor] CGColor];
                    navView.layer.opaque = NO;
                }
                
                if ([navView respondsToSelector:@selector(setBackgroundColor:)]) {
                    @try { [(id)navView setBackgroundColor:[NSColor clearColor]]; } @catch (NSException *e) {}
                }
                
                if ([navView respondsToSelector:@selector(setDrawsBackground:)]) {
                    @try { [(id)navView setDrawsBackground:NO]; } @catch (NSException *e) {}
                }
                
                // Ensure glass stays at bottom
                NSView *glass = navigationBlurViews[@((NSUInteger)navView)];
                if (glass && glass.superview == navView) {
                    NSUInteger glassIndex = [navView.subviews indexOfObject:glass];
                    if (glassIndex != 0 && navView.subviews.count > 1) {
                        [glass removeFromSuperview];
                        [navView addSubview:glass positioned:NSWindowBelow relativeTo:navView.subviews.firstObject];
                        if (glass.layer) glass.layer.zPosition = -1000.0;
                    }
                }
            }];
            navTimers[navKey] = timer;
        }
    }
}

// Remove Liquid Glass effects from a window
static void removeBlurEffectsFromWindow(NSWindow *window) {
    if (!windowBlurViews) return;
    
    NSNumber *windowKey = @((NSUInteger)window);
    NSView *glassView = windowBlurViews[windowKey];
    
    if (glassView) {
        [glassView removeFromSuperview];
        [windowBlurViews removeObjectForKey:windowKey];
    }
    
    // Remove navigation blur views
    removeNavigationBlurFromWindow(window);
    
    // Restore original window appearance (solid background)
    window.backgroundColor = [NSColor windowBackgroundColor];
    window.opaque = YES;
    window.titlebarAppearsTransparent = NO;
}

// Remove navigation blur effects
static void removeNavigationBlurFromWindow(NSWindow *window) {
    if (!navigationBlurViews || !window.contentView) return;
    
    // Find all navigation views and remove their blur views
    NSMutableArray *navigationViews = [NSMutableArray array];
    findNavigationViewsRecursive(window.contentView, navigationViews);
    
    for (NSView *navView in navigationViews) {
        NSNumber *viewKey = @((NSUInteger)navView);
        NSView *navGlassView = navigationBlurViews[viewKey];
        
        if (navGlassView) {
            [navGlassView removeFromSuperview];
            [navigationBlurViews removeObjectForKey:viewKey];
            [trackedNavigationViews removeObject:navView];
        }
        
        // Restore original background
        if ([navView respondsToSelector:@selector(setBackgroundColor:)]) {
            [(id)navView setBackgroundColor:[NSColor controlBackgroundColor]];
        }
    }
}

// Update all existing windows
static void updateAllWindows(BOOL enable) {
    NSArray<NSWindow *> *windows = [NSApplication sharedApplication].windows;
    for (NSWindow *window in windows) {
        if (enable) {
            applyBlurEffectsToWindow(window);
        } else {
            removeBlurEffectsFromWindow(window);
        }
    }
}

// Update intensity on all active glass views (currently not used - glass is always full opacity)
static void updateIntensityOnAllViews(void) {
    // Note: Liquid Glass with clear style doesn't use alpha-based intensity
    // The blur effect is controlled by the glass material itself
    // This function is kept for future customization if needed
    NSLog(@"[BlurTweak] Intensity updates not applicable to Liquid Glass clear style");
}

// Recursively make views transparent to allow Glass effect through
static void makeViewHierarchyTransparent(NSView *view, BOOL transparent) {
    if (!view) return;
    
    // Skip our own Glass effect views
    if ([view isKindOfClass:NSClassFromString(@"NSGlassEffectView")] ||
        [view isKindOfClass:NSClassFromString(@"NSGlassEffectContainerView")]) {
        return;
    }
    
    // CRITICAL: Neutralize Finder's NSVisualEffectView (the black backdrop)
    if ([view isKindOfClass:[NSVisualEffectView class]]) {
        NSLog(@"[BlurTweak] Found NSVisualEffectView in hierarchy - neutralizing it");
        view.alphaValue = 0.0;
        view.hidden = YES;
        // Optionally remove it
        // [view removeFromSuperview];
        return; // Don't recurse into it
    }
    
    if (transparent) {
        // CRITICAL: DO NOT use wantsLayer = YES - it causes coordinate system flipping!
        // Only work with views that already have layers
        
        // Clear ALL possible background properties without forcing layer-backing
        if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
            @try {
                [(id)view setDrawsBackground:NO];
            } @catch (NSException *e) {
                // Ignore
            }
        }
        
        if ([view respondsToSelector:@selector(setBackgroundColor:)]) {
            @try {
                [(id)view setBackgroundColor:[NSColor clearColor]];
            } @catch (NSException *e) {
                // Ignore
            }
        }
        
        // Only modify layer if it already exists
        if (view.layer) {
            view.layer.opaque = NO;
            view.layer.backgroundColor = [[NSColor clearColor] CGColor];
        }
        
        // For scroll views, make them transparent
        if ([view isKindOfClass:[NSScrollView class]]) {
            NSScrollView *scrollView = (NSScrollView *)view;
            scrollView.drawsBackground = NO;
            scrollView.backgroundColor = [NSColor clearColor];
        }
        
        // For clip views
        if ([view isKindOfClass:[NSClipView class]]) {
            NSClipView *clipView = (NSClipView *)view;
            clipView.drawsBackground = NO;
            clipView.backgroundColor = [NSColor clearColor];
        }
    }
    
    // Recursively apply to ALL subviews
    for (NSView *subview in [view.subviews copy]) {
        makeViewHierarchyTransparent(subview, transparent);
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
    
    // Navigation blur toggle
    notify_register_dispatch("com.blur.tweak.navigation.toggle", &token,
                             dispatch_get_main_queue(), ^(int t) {
        (void)t;
        enableNavigationBlur = !enableNavigationBlur;
        updateAllWindows(enableBlurTweak);
    });
    
    // Intensity notification (deprecated - not used with Liquid Glass)
    notify_register_dispatch("com.blur.tweak.intensity", &token,
                             dispatch_get_main_queue(), ^(int t) {
        (void)t;
        NSLog(@"[BlurTweak] Intensity adjustments not supported with Liquid Glass clear style");
    });
    
    // Appearance change notification
    [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"AppleInterfaceThemeChangedNotification"
                                                                object:nil
                                                                 queue:NSOperationQueue.mainQueue
                                                            usingBlock:^(NSNotification *note) {
        (void)note;
        NSLog(@"[BlurTweak] System appearance changed (Liquid Glass handles this automatically)");
        // No manual material updates needed - NSGlassEffectView adapts automatically
    }];
}

#pragma mark - Swizzled NSWindow

ZKSwizzleInterfaceGroup(BlurTweak_NSWindow, NSWindow, NSWindow, BLUR_TWEAK_GROUP)
@implementation BlurTweak_NSWindow

- (id)initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backingStoreType defer:(BOOL)flag {
    id result = ZKOrig(id, contentRect, style, backingStoreType, flag);
    if (result && enableBlurTweak) {
        // FORCE TRANSPARENCY IMMEDIATELY on creation
        NSWindow *window = (NSWindow *)result;
        window.backgroundColor = [NSColor clearColor];
        window.opaque = NO;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            applyBlurEffectsToWindow(window);
        });
    }
    return result;
}

- (void)setFrame:(NSRect)frameRect display:(BOOL)flag {
    ZKOrig(void, frameRect, flag);
    
    if (enableBlurTweak && shouldApplyBlurEffects(self)) {
        self.backgroundColor = [NSColor clearColor];
        self.opaque = NO;
        
        NSView *blurView = getBlurViewForWindow(self);
        if (blurView && blurView.superview) {
            blurView.frame = NSInsetRect(self.contentView.bounds, -2.0, -2.0);
            if (blurView.layer) applyCornerMasking(blurView.layer, 10.0);
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            applyBlurEffectsToWindow(self);
        });
    }
}

- (void)orderFront:(id)sender {
    // FORCE TRANSPARENCY before making visible
    if (enableBlurTweak && shouldApplyBlurEffects(self)) {
        self.backgroundColor = [NSColor clearColor];
        self.opaque = NO;
        applyBlurEffectsToWindow(self);
    }
    
    ZKOrig(void, sender);
}

- (void)setContentView:(NSView *)contentView {
    ZKOrig(void, contentView);
    
    // FORCE transparency after contentView is set
    if (enableBlurTweak && shouldApplyBlurEffects(self)) {
        self.backgroundColor = [NSColor clearColor];
        self.opaque = NO;
        
        // Make the contentView itself transparent
        if (contentView) {
            contentView.wantsLayer = YES;
            if (contentView.layer) {
                contentView.layer.backgroundColor = [[NSColor clearColor] CGColor];
                contentView.layer.opaque = NO;
            }
        }
        
        // Reapply blur effects
        dispatch_async(dispatch_get_main_queue(), ^{
            applyBlurEffectsToWindow(self);
        });
    }
}

- (void)setBackgroundColor:(NSColor *)backgroundColor {
    // INTERCEPT: Never allow opaque background if blur is enabled
    if (enableBlurTweak && shouldApplyBlurEffects(self)) {
        ZKOrig(void, [NSColor clearColor]); // FORCE clear color
    } else {
        ZKOrig(void, backgroundColor);
    }
}

- (void)setOpaque:(BOOL)opaque {
    // INTERCEPT: Never allow opaque windows if blur is enabled
    if (enableBlurTweak && shouldApplyBlurEffects(self)) {
        ZKOrig(void, NO); // FORCE non-opaque
    } else {
        ZKOrig(void, opaque);
    }
}

- (void)close {
    if (enableBlurTweak) {
        removeBlurEffectsFromWindow(self);
    }
    ZKOrig(void);
}

- (void)becomeKeyWindow {
    ZKOrig(void);
    
    // Reapply transparency when window becomes key (e.g., after switching directories)
    if (enableBlurTweak && shouldApplyBlurEffects(self)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            applyBlurEffectsToWindow(self);
        });
    }
}

- (void)makeKeyAndOrderFront:(id)sender {
    ZKOrig(void, sender);
    
    // Reapply transparency when window is brought to front
    if (enableBlurTweak && shouldApplyBlurEffects(self)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            applyBlurEffectsToWindow(self);
        });
    }
}

// Handle appearance changes
- (void)setAppearance:(NSAppearance *)appearance {
    ZKOrig(void, appearance);
    
    // No manual material updates needed - NSGlassEffectView adapts automatically to appearance changes
}

@end

#pragma mark - Swizzled NSScrollView (force transparent backgrounds)

ZKSwizzleInterfaceGroup(BlurTweak_NSScrollView, NSScrollView, NSScrollView, BLUR_TWEAK_GROUP)
@implementation BlurTweak_NSScrollView

- (void)setDrawsBackground:(BOOL)drawsBackground {
    // FORCE no background if blur is enabled
    if (enableBlurTweak && self.window && shouldApplyBlurEffects(self.window)) {
        ZKOrig(void, NO);
    } else {
        ZKOrig(void, drawsBackground);
    }
}

- (void)setBackgroundColor:(NSColor *)backgroundColor {
    // FORCE clear background if blur is enabled
    if (enableBlurTweak && self.window && shouldApplyBlurEffects(self.window)) {
        ZKOrig(void, [NSColor clearColor]);
    } else {
        ZKOrig(void, backgroundColor);
    }
}

@end

#pragma mark - Swizzled NSClipView (force transparent backgrounds)

ZKSwizzleInterfaceGroup(BlurTweak_NSClipView, NSClipView, NSClipView, BLUR_TWEAK_GROUP)
@implementation BlurTweak_NSClipView

- (void)setDrawsBackground:(BOOL)drawsBackground {
    // FORCE no background if blur is enabled
    if (enableBlurTweak && self.window && shouldApplyBlurEffects(self.window)) {
        ZKOrig(void, NO);
    } else {
        ZKOrig(void, drawsBackground);
    }
}

- (void)setBackgroundColor:(NSColor *)backgroundColor {
    // FORCE clear background if blur is enabled
    if (enableBlurTweak && self.window && shouldApplyBlurEffects(self.window)) {
        ZKOrig(void, [NSColor clearColor]);
    } else {
        ZKOrig(void, backgroundColor);
    }
}

@end

#pragma mark - Swizzled NSView (for navigation view tracking and transparency)

ZKSwizzleInterfaceGroup(BlurTweak_NSView, NSView, NSView, BLUR_TWEAK_GROUP)
@implementation BlurTweak_NSView

- (void)viewDidMoveToWindow {
    ZKOrig(void);
    
    // Early return if not Finder or blur disabled
    if (!enableBlurTweak || !self.window || !shouldApplyBlurEffects(self.window)) {
        return;
    }
    
    NSString *className = NSStringFromClass([self class]);
    
    // Skip Glass effect views themselves
    if ([self isKindOfClass:NSClassFromString(@"NSGlassEffectView")] ||
        [self isKindOfClass:NSClassFromString(@"NSGlassEffectContainerView")]) {
        return;
    }
    
    // CRITICAL: Remove Finder's NSVisualEffectView immediately
    if ([self isKindOfClass:[NSVisualEffectView class]]) {
        NSLog(@"[BlurTweak] Found NSVisualEffectView being added - neutralizing it");
        self.alphaValue = 0.0;
        self.hidden = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self removeFromSuperview];
        });
        return;
    }
    
    // TARGET: Finder UI elements for transparency
    if (isFinderUIElement(className)) {
        makeFinderViewTransparent(self, className);
        return; // Early return after handling targeted elements
    }
    
    // FALLBACK: General transparency for all other Finder views
    // DO NOT use wantsLayer - causes coordinate system flip
    if (self.layer) {
        self.layer.opaque = NO;
        self.layer.backgroundColor = [[NSColor clearColor] CGColor];
    }
    
    // Special handling for scroll views
    if ([self isKindOfClass:[NSScrollView class]]) {
        NSScrollView *scrollView = (NSScrollView *)self;
        scrollView.drawsBackground = NO;
        scrollView.backgroundColor = [NSColor clearColor];
    }
    
    // Special handling for clip views
    if ([self isKindOfClass:[NSClipView class]]) {
        NSClipView *clipView = (NSClipView *)self;
        clipView.drawsBackground = NO;
        clipView.backgroundColor = [NSColor clearColor];
    }
    
    // Navigation blur handling
    if (enableNavigationBlur && isNavigationView(self)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (shouldApplyBlurEffects(self.window)) {
                applyNavigationBlurToWindow(self.window);
            }
        });
    }
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    ZKOrig(void, newWindow);
    
    // Catch directory changes - reapply transparency when views are being reorganized
    if (enableBlurTweak && newWindow && shouldApplyBlurEffects(newWindow)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            applyBlurEffectsToWindow(newWindow);
        });
    }
}

- (void)setFrame:(NSRect)frame {
    ZKOrig(void, frame);
    
    if (enableBlurTweak && enableNavigationBlur && isNavigationView(self)) {
        NSNumber *viewKey = @((NSUInteger)self);
        NSView *navBlurView = navigationBlurViews[viewKey];
        if (navBlurView) {
            navBlurView.frame = NSInsetRect(self.bounds, -1.0, -1.0);
            if (navBlurView.layer) applyCornerMasking(navBlurView.layer, 6.0);
        }
    }
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    ZKOrig(void, oldSize);
    
    if (enableBlurTweak && enableNavigationBlur && isNavigationView(self)) {
        NSNumber *viewKey = @((NSUInteger)self);
        NSView *navBlurView = navigationBlurViews[viewKey];
        if (navBlurView) {
            navBlurView.frame = NSInsetRect(self.bounds, -1.0, -1.0);
            if (navBlurView.layer) applyCornerMasking(navBlurView.layer, 6.0);
        }
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    // Intercept drawing for Finder UI elements - prevent opaque backgrounds
    if (enableBlurTweak && self.window && shouldApplyBlurEffects(self.window)) {
        NSString *className = NSStringFromClass([self class]);
        
        if (isFinderUIElement(className)) {
            // Don't draw anything - just clear to transparent
            [[NSColor clearColor] setFill];
            NSRectFill(dirtyRect);
            return;
        }
    }
    
    // Call original drawing for non-targeted views
    ZKOrig(void, dirtyRect);
}

@end

#pragma mark - Constructor

__attribute__((constructor))
static void initializeBlurTweak(void) {
    @autoreleasepool {
        // CRITICAL: Check if we're in Finder BEFORE activating swizzles
        if (!isFinderProcess()) {
            NSLog(@"[BlurTweak] Not Finder - tweak will not activate");
            return;
        }
        
        if (!checkLiquidGlassAvailability()) {
            NSLog(@"[BlurTweak] ERROR: NSGlassEffectView not available (requires macOS 26.0+)");
            return;
        }
        
        NSLog(@"[BlurTweak] Initializing Liquid Glass tweak");
        
        // Activate the swizzles ONLY in Finder
        ZKSwizzleGroup(BLUR_TWEAK_GROUP);
        
        loadPersistentSettings();
        registerNotificationHandlers();
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), 
                      dispatch_get_main_queue(), ^{
            updateAllWindows(enableBlurTweak);
        });
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), 
                      dispatch_get_main_queue(), ^{
            updateAllWindows(enableBlurTweak);
        });
    }
}