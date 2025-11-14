@import Foundation;
@import AppKit;
@import QuartzCore;
@import CoreVideo;
#import <objc/runtime.h>
#import "../ZKSwizzle/ZKSwizzle.h"

/**
 * AeroFinder - Finder Glass Effect Tweak
 * 
 * IMPLEMENTATION:
 * - Hides Finder's background by removing/hiding NSVisualEffectView
 * - Adds NSGlassEffectView with .clear style to navigation windows
 * - Makes content behind Finder visible through glass effect
 * 
 * REQUIREMENTS:
 * - macOS 26.0+ for NSGlassEffectView
 * - Finder-only injection
 * 
 * @author rennnss
 * @version 2.0
 * @date 2025-11-13
 */

#pragma mark - Configuration

static BOOL tweakEnabled = YES;
static BOOL glassAvailable = NO;
static NSMutableDictionary *glassViews = nil;
static NSMutableDictionary *windowTimers = nil;
static NSMutableDictionary<NSNumber *, NSNumber *> *windowMaintenanceTimestamps = nil;
static NSMutableDictionary<NSNumber *, NSValue *> *windowDisplayLinks = nil;
static NSMutableDictionary<NSNumber *, NSNumber *> *windowScrollTimestamps = nil;
static NSColor *clearColorCache = nil;  // Performance: Cache clear color to avoid repeated allocations
static const NSTimeInterval kWindowMaintenanceInterval = 0.018;  // Throttle heavy passes per window (≈55Hz)
static const NSTimeInterval kScrollActivityWindow = 0.5;  // Consider window "scrolling" for 500ms after last scroll

#pragma mark - Helper Functions

// Check if running in Finder
static inline BOOL isFinderProcess(void) {
    static dispatch_once_t onceToken;
    static BOOL isFinder = NO;
    dispatch_once(&onceToken, ^{
        isFinder = [[[NSProcessInfo processInfo] processName] isEqualToString:@"Finder"];
    });
    return isFinder;
}

// Check NSGlassEffectView availability
static inline BOOL checkGlassAvailability(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        glassAvailable = (NSClassFromString(@"NSGlassEffectView") != nil);
        NSLog(@"[AeroFinder] NSGlassEffectView available: %@", glassAvailable ? @"YES" : @"NO");
    });
    return glassAvailable;
}

// Forward declarations for display link helpers
static inline void ensureTransparentScrollStack(NSScrollView *scrollView);
static void refreshScrollStacksInView(NSView *view, NSInteger depth);
static void refreshScrollStacksForWindow(NSWindow *window);
static void stopDisplayLinkForWindow(NSWindow *window);
static CVReturn displayLinkCallback(CVDisplayLinkRef link,
                                    const CVTimeStamp *inNow,
                                    const CVTimeStamp *inOutputTime,
                                    CVOptionFlags flagsIn,
                                    CVOptionFlags *flagsOut,
                                    void *displayLinkContext);
static void applyGlassEffect(NSWindow *window);
static void removeGlassEffect(NSWindow *window);
static void processTitlebarArea(NSWindow *window);

// Check if window is in fullscreen mode
static inline BOOL isWindowFullscreen(NSWindow *window) {
    if (!window) return NO;
    return (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}

// Ensure clearColorCache is initialized
static inline NSColor *getClearColor(void) {
    if (!clearColorCache) clearColorCache = [NSColor clearColor];
    return clearColorCache;
}

// Set window transparency
static inline void setWindowTransparent(NSWindow *window) {
    window.backgroundColor = getClearColor();
    window.opaque = NO;
}

// Helper macro for CATransaction blocks
#define BEGIN_NO_ANIMATION \
    [CATransaction begin]; \
    [CATransaction setDisableActions:YES]; \
    [CATransaction setAnimationDuration:0];
#define END_NO_ANIMATION [CATransaction commit];

// Check if window should be modified
static inline BOOL shouldModifyWindow(NSWindow *window) {
    if (!window || !tweakEnabled || !isFinderProcess()) return NO;
    
    // EXCLUDE: Fullscreen windows - disable blur effect in fullscreen
    if (isWindowFullscreen(window)) return NO;
    
    // EXCLUDE: TGoToWindowController and related windows - never touch these
    NSString *windowClassName = NSStringFromClass([window class]);
    
    // Check window class name
    if ([windowClassName isEqualToString:@"TGoToWindowController"]) return NO;
    if ([windowClassName containsString:@"TGoToWindow"]) return NO;
    if ([windowClassName containsString:@"GoToWindow"]) return NO;
    
    // EXCLUDE: QuickLook windows - prevent WebKit initialization conflicts
    if ([windowClassName containsString:@"QLPreview"]) return NO;
    if ([windowClassName containsString:@"QuickLook"]) return NO;
    
    // Check window controller class name
    if (window.windowController) {
        NSString *controllerClassName = NSStringFromClass([window.windowController class]);
        if ([controllerClassName isEqualToString:@"TGoToWindowController"]) return NO;
        if ([controllerClassName containsString:@"TGoToWindow"]) return NO;
        if ([controllerClassName containsString:@"GoToWindow"]) return NO;
        if ([controllerClassName containsString:@"QLPreview"]) return NO;
        if ([controllerClassName containsString:@"QuickLook"]) return NO;
    }
    
    // Check window title for Go To dialog
    if ([window.title containsString:@"Go to"] || 
        [window.title containsString:@"Go To"] ||
        [window.title isEqualToString:@"Go to the Folder:"]) return NO;
    
    // Only normal Finder windows
    if (window.level != NSNormalWindowLevel) return NO;
    if ([window isKindOfClass:[NSPanel class]]) return NO;
    if (!(window.styleMask & NSWindowStyleMaskTitled)) return NO;
    if (!window.contentView) return NO;
    
    return YES;
}

// Set glass style to clear using runtime invocation
static void setGlassStyleClear(NSView *glassView) {
    SEL styleSelector = NSSelectorFromString(@"setStyle:");
    if ([glassView respondsToSelector:styleSelector]) {
        // NSGlassEffectView.Style.clear = 0
        NSInteger clearStyle = 0;
        NSMethodSignature *sig = [glassView methodSignatureForSelector:styleSelector];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
        [invocation setSelector:styleSelector];
        [invocation setTarget:glassView];
        [invocation setArgument:&clearStyle atIndex:2];
        [invocation invoke];
    }
}

// Check if view belongs to QuickLook or WebKit
static inline BOOL isQuickLookOrWebKitView(NSView *view) {
    if (!view) return NO;
    
    // Check view class names
    NSString *className = NSStringFromClass([view class]);
    if ([className containsString:@"QL"] ||
        [className containsString:@"QuickLook"] ||
        [className containsString:@"Web"] ||
        [className containsString:@"WebKit"]) {
        return YES;
    }
    
    // Check if in QuickLook/WebKit hierarchy
    NSView *current = view;
    while (current) {
        NSString *currentClassName = NSStringFromClass([current class]);
        if ([currentClassName containsString:@"QL"] ||
            [currentClassName containsString:@"QuickLook"] ||
            [currentClassName containsString:@"Web"] ||
            [currentClassName containsString:@"WebKit"]) {
            return YES;
        }
        current = current.superview;
    }
    
    return NO;
}

// Hide all NSVisualEffectView in hierarchy
static void hideVisualEffectViews(NSView *view) {
    if (!view) return;
    
    // CRITICAL: Skip QuickLook/WebKit views
    if (isQuickLookOrWebKitView(view)) return;
    
    // CRITICAL: Skip views from excluded windows
    if (view.window && !shouldModifyWindow(view.window)) return;
    
    for (NSView *subview in [view.subviews copy]) {
        if ([subview isKindOfClass:[NSVisualEffectView class]]) {
            NSLog(@"[AeroFinder] Hiding NSVisualEffectView");
            subview.hidden = YES;
            subview.alphaValue = 0.0;
        }
        hideVisualEffectViews(subview);
    }
}

// Force hide problematic background views
static void forceHideBackgrounds(NSView *view);

// Remove known Finder background wrappers without deep recursion
static inline void pruneImmediateBackgroundViews(NSView *view) {
    if (!view) return;
    if (isQuickLookOrWebKitView(view)) return;
    NSArray *subviews = [view.subviews copy];
    for (NSView *subview in subviews) {
        if (isQuickLookOrWebKitView(subview)) continue;
        NSString *className = NSStringFromClass([subview class]);
        BOOL isBackgroundClass = ([className isEqualToString:@"NSTitlebarBackgroundView"] ||
                                  [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
                                  [className isEqualToString:@"BackdropView"]);
        if ([subview isKindOfClass:[NSVisualEffectView class]] || isBackgroundClass) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [subview removeFromSuperview];
            });
            continue;
        }
        // Tight loop: only examine one level down to avoid heavy work
        if ([subview isKindOfClass:[NSScrollView class]] || [subview isKindOfClass:[NSClipView class]]) {
            continue; // handled separately via ensureTransparentScrollStack
        }
        if ([subview respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [(id)subview setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        NSColor *clear = getClearColor();
        if ([subview respondsToSelector:@selector(setBackgroundColor:)]) {
            @try { [(id)subview setBackgroundColor:clear]; } @catch (NSException *e) {}
        }
    }
}

static void refreshScrollStacksInView(NSView *view, NSInteger depth) {
    if (!view || depth > 3) return;
    if (isQuickLookOrWebKitView(view)) return;
    if ([view isKindOfClass:[NSScrollView class]]) {
        ensureTransparentScrollStack((NSScrollView *)view);
        // Depth-limited pruning keeps surrounding wrappers quiet
        pruneImmediateBackgroundViews(view);
    } else {
        pruneImmediateBackgroundViews(view);
    }
    if (depth == 3) return;
    for (NSView *subview in [view.subviews copy]) {
        refreshScrollStacksInView(subview, depth + 1);
    }
}

static void refreshScrollStacksForWindow(NSWindow *window) {
    if (!window || !window.contentView) return;
    refreshScrollStacksInView(window.contentView, 0);
}

// Mark window as actively scrolling
static inline void markWindowScrolling(NSWindow *window) {
    if (!window) return;
    if (!windowScrollTimestamps) {
        windowScrollTimestamps = [NSMutableDictionary dictionary];
    }
    NSNumber *key = @((uintptr_t)window);
    windowScrollTimestamps[key] = @(CFAbsoluteTimeGetCurrent());
}

// Check if window is currently in scroll activity window
static inline BOOL isWindowScrolling(NSWindow *window) {
    if (!window || !windowScrollTimestamps) return NO;
    NSNumber *key = @((uintptr_t)window);
    NSNumber *lastScroll = windowScrollTimestamps[key];
    if (!lastScroll) return NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    return (now - lastScroll.doubleValue) < kScrollActivityWindow;
}

// Lightweight refresh for scroll stacks without walking entire view tree
static inline void ensureTransparentScrollStack(NSScrollView *scrollView) {
    if (!scrollView) return;
    if (isQuickLookOrWebKitView(scrollView)) return;
    NSColor *clear = getClearColor();
    
    // Mark window as scrolling for aggressive cleanup
    if (scrollView.window) {
        markWindowScrolling(scrollView.window);
    }
    
    void (^applyTransparency)(NSView *) = ^(NSView *view) {
        if (!view || isQuickLookOrWebKitView(view)) return;
        
        // Enable layer backing for consistent transparency
        if (!view.wantsLayer) {
            view.wantsLayer = YES;
        }
        
        if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [(id)view setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        if ([view respondsToSelector:@selector(setBackgroundColor:)]) {
            @try { [(id)view setBackgroundColor:clear]; } @catch (NSException *e) {}
        }
        if (view.layer) {
            view.layer.backgroundColor = [clear CGColor];
            view.layer.opaque = NO;
        }
    };
    
    void (^hideBackgroundLayer)(NSView *) = ^(NSView *view) {
        if (!view || isQuickLookOrWebKitView(view)) return;
        NSString *className = NSStringFromClass([view class]);
        
        // Target ONLY background views, not content views
        BOOL isBackgroundView = ([view isKindOfClass:[NSVisualEffectView class]] ||
                                [className isEqualToString:@"NSTitlebarBackgroundView"] ||
                                [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
                                [className isEqualToString:@"BackdropView"] ||
                                [className hasSuffix:@"BackgroundView"]);
        
        // Use layer-based transparency for background views only
        if (isBackgroundView) {
            if (view.layer || view.wantsLayer) {
                if (!view.wantsLayer) view.wantsLayer = YES;
                view.layer.opacity = 0.0;
                view.layer.backgroundColor = [[NSColor clearColor] CGColor];
                if ([view isKindOfClass:[NSVisualEffectView class]]) {
                    view.hidden = YES;
                }
            }
            // Disable drawing for background views
            if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
                @try { [(id)view setDrawsBackground:NO]; } @catch (NSException *e) {}
            }
        } else {
            // For non-background views, just ensure transparent background color
            if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
                @try { [(id)view setDrawsBackground:NO]; } @catch (NSException *e) {}
            }
        }
    };
    
    applyTransparency(scrollView);
    NSClipView *clipView = scrollView.contentView;
    applyTransparency(clipView);
    
    // Fast layer-based hiding for backgrounds - be more thorough
    for (NSView *subview in scrollView.subviews) {
        hideBackgroundLayer(subview);
        applyTransparency(subview);
    }
    for (NSView *subview in clipView.subviews) {
        hideBackgroundLayer(subview);
        applyTransparency(subview);
    }
    
    if ([clipView isKindOfClass:[NSClipView class]]) {
        NSView *documentView = clipView.documentView;
        if ([documentView isKindOfClass:[NSVisualEffectView class]]) {
            hideBackgroundLayer(documentView);
        } else {
            applyTransparency(documentView);
            
            // Apply to ALL subviews in document view to catch list backgrounds
            NSArray *allSubviews = [documentView.subviews copy];
            for (NSView *subview in allSubviews) {
                NSString *subviewClass = NSStringFromClass([subview class]);
                // Hide known background views completely
                if ([subview isKindOfClass:[NSVisualEffectView class]] ||
                    [subviewClass hasSuffix:@"BackgroundView"] ||
                    [subviewClass isEqualToString:@"BackdropView"]) {
                    hideBackgroundLayer(subview);
                }
                // But apply transparency to everything
                applyTransparency(subview);
            }
        }
    }
}

// Comprehensive but throttled background removal (called sparingly)
static void forceHideBackgrounds(NSView *view) {
    if (!view) return;
    if (isQuickLookOrWebKitView(view)) return;
    if (view.window && !shouldModifyWindow(view.window)) return;
    
    // Enable layer backing for all views to ensure proper transparency
    if (!view.wantsLayer) {
        view.wantsLayer = YES;
    }
    
    NSArray *subviews = [view.subviews copy];
    for (NSView *subview in subviews) {
        if (isQuickLookOrWebKitView(subview)) continue;
        
        // Enable layer backing
        if (!subview.wantsLayer) {
            subview.wantsLayer = YES;
        }
        
        NSString *className = NSStringFromClass([subview class]);
        BOOL isBackgroundClass = ([subview isKindOfClass:[NSVisualEffectView class]] ||
                                  [className isEqualToString:@"NSTitlebarBackgroundView"] ||
                                  [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
                                  [className isEqualToString:@"BackdropView"] ||
                                  [className hasSuffix:@"BackgroundView"]);
        if (isBackgroundClass) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [subview removeFromSuperview];
            });
            continue;
        }
        
        // Apply transparency to all views
        if ([subview respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [(id)subview setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        NSColor *clear = getClearColor();
        if ([subview respondsToSelector:@selector(setBackgroundColor:)]) {
            @try { [(id)subview setBackgroundColor:clear]; } @catch (NSException *e) {}
        }
        if (subview.layer) {
            subview.layer.backgroundColor = [clear CGColor];
            subview.layer.opaque = NO;
        }
        forceHideBackgrounds(subview);
    }
}

static void stopDisplayLinkForKey(NSNumber *key) {
    if (!windowDisplayLinks || !key) return;
    NSValue *linkValue = windowDisplayLinks[key];
    if (!linkValue) return;
    CVDisplayLinkRef link = (CVDisplayLinkRef)[linkValue pointerValue];
    if (link) {
        CVDisplayLinkStop(link);
        CVDisplayLinkRelease(link);
    }
    [windowDisplayLinks removeObjectForKey:key];
}

static void stopDisplayLinkForWindow(NSWindow *window) {
    if (!window) return;
    NSNumber *key = @((uintptr_t)window);
    stopDisplayLinkForKey(key);
}

static CVReturn displayLinkCallback(CVDisplayLinkRef link,
                                    const CVTimeStamp *inNow,
                                    const CVTimeStamp *inOutputTime,
                                    CVOptionFlags flagsIn,
                                    CVOptionFlags *flagsOut,
                                    void *displayLinkContext) {
    @autoreleasepool {
    (void)link;
    (void)inNow;
    (void)inOutputTime;
    (void)flagsIn;
    (void)flagsOut;
        NSWindow *window = (__bridge NSWindow *)displayLinkContext;
        if (!window) return kCVReturnSuccess;
        
        // Use weak reference to avoid retaining window
        __weak NSWindow *weakWindow = window;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSWindow *strongWindow = weakWindow;
            if (!tweakEnabled || !strongWindow || !strongWindow.contentView) return;
            if (!shouldModifyWindow(strongWindow)) return;
            
            NSNumber *key = @((uintptr_t)strongWindow);
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            NSNumber *lastMaintenance = windowMaintenanceTimestamps[key];
            if (lastMaintenance && (now - lastMaintenance.doubleValue) < kWindowMaintenanceInterval) {
                return;
            }
            windowMaintenanceTimestamps[key] = @(now);
            refreshScrollStacksForWindow(strongWindow);
        });
    }
    return kCVReturnSuccess;
}

// Fix sidebar titlebar views - make them transparent
static void fixSidebarTitlebarViews(NSView *view) {
    if (!view || isQuickLookOrWebKitView(view)) return;
    
    NSString *className = NSStringFromClass([view class]);
    BOOL isSidebarRelated = ([className containsString:@"Sidebar"] ||
                             [className containsString:@"SourceList"] ||
                             [className containsString:@"Browser"] ||
                             [className containsString:@"TNode"] ||
                             [className containsString:@"Title"] ||
                             [className containsString:@"Header"] ||
                             [className containsString:@"Section"] ||
                             [className hasSuffix:@"HeaderView"] ||
                             [className hasSuffix:@"TitleView"]);
    
    if (isSidebarRelated) {
        NSColor *clear = getClearColor();
        if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [(id)view setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        if ([view respondsToSelector:@selector(setBackgroundColor:)]) {
            @try { [(id)view setBackgroundColor:clear]; } @catch (NSException *e) {}
        }
        if (!view.wantsLayer) view.wantsLayer = YES;
        if (view.layer) {
            view.layer.backgroundColor = [getClearColor() CGColor];
            view.layer.opaque = NO;
        }
        
        for (NSView *subview in view.subviews) {
            NSString *subviewClass = NSStringFromClass([subview class]);
            if ([subview isKindOfClass:[NSVisualEffectView class]] ||
                [subviewClass hasSuffix:@"BackgroundView"] ||
                [subviewClass isEqualToString:@"BackdropView"] ||
                [subviewClass containsString:@"Background"] ||
                [subviewClass containsString:@"Fill"] ||
                [subviewClass containsString:@"Separator"]) {
                subview.hidden = YES;
                subview.alphaValue = 0.0;
                if (subview.layer) subview.layer.opacity = 0.0;
            }
        }
    }
    
    for (NSView *subview in view.subviews) {
        fixSidebarTitlebarViews(subview);
    }
}

// Make view hierarchy transparent
static void makeTransparent(NSView *view) {
    if (!view) return;
    
    // CRITICAL: Skip QuickLook/WebKit views completely
    if (isQuickLookOrWebKitView(view)) return;
    
    // CRITICAL: Skip views from excluded windows
    if (view.window && !shouldModifyWindow(view.window)) return;
    
    // Skip glass views
    if ([view isKindOfClass:NSClassFromString(@"NSGlassEffectView")]) return;
    
    // Hide NSVisualEffectView
    if ([view isKindOfClass:[NSVisualEffectView class]]) {
        view.hidden = YES;
        view.alphaValue = 0.0;
        return;
    }
    
    // Make backgrounds transparent
    if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
        @try { [(id)view setDrawsBackground:NO]; } @catch (NSException *e) {}
    }
    
    NSColor *clear = getClearColor();
    if ([view respondsToSelector:@selector(setBackgroundColor:)]) {
        @try { [(id)view setBackgroundColor:clear]; } @catch (NSException *e) {}
    }
    
    // Recurse
    for (NSView *subview in [view.subviews copy]) {
        makeTransparent(subview);
    }
}

// Start timer to continuously force hide backgrounds
static void startBackgroundHidingTimer(NSWindow *window) {
    if (!window) return;

    if (!windowTimers) {
        windowTimers = [NSMutableDictionary dictionary];
    }
    if (!windowMaintenanceTimestamps) {
        windowMaintenanceTimestamps = [NSMutableDictionary dictionary];
    }
    if (!windowDisplayLinks) {
        windowDisplayLinks = [NSMutableDictionary dictionary];
    }

    NSNumber *key = @((uintptr_t)window);
    __weak NSWindow *weakWindow = window;

    // Cancel existing timer if any
    NSTimer *existingTimer = windowTimers[key];
    if (existingTimer && existingTimer.valid) {
        [existingTimer invalidate];
    }
    
    // Create timer at ~30Hz for lightweight maintenance, heavy work only during scroll
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.033
                                                       repeats:YES
                                                         block:^(NSTimer *timer) {
        NSWindow *strongWindow = weakWindow;
        if (!strongWindow || !strongWindow.contentView) {
            [timer invalidate];
            stopDisplayLinkForKey(key);
            [windowTimers removeObjectForKey:key];
            [windowMaintenanceTimestamps removeObjectForKey:key];
            return;
        }
        
        if (!shouldModifyWindow(strongWindow)) {
            [timer invalidate];
            stopDisplayLinkForKey(key);
            [windowTimers removeObjectForKey:key];
            [windowMaintenanceTimestamps removeObjectForKey:key];
            return;
        }

        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        NSNumber *maintenanceKey = @((uintptr_t)strongWindow);
        NSNumber *lastMaintenance = windowMaintenanceTimestamps[maintenanceKey];
        if (lastMaintenance && (now - lastMaintenance.doubleValue) < kWindowMaintenanceInterval) {
            return;
        }
        windowMaintenanceTimestamps[maintenanceKey] = @(now);
        
        BEGIN_NO_ANIMATION
        setWindowTransparent(strongWindow);
        processTitlebarArea(strongWindow);
        if (isWindowScrolling(strongWindow)) refreshScrollStacksForWindow(strongWindow);
        
        NSView *glassView = glassViews[key];
        if (glassView && glassView.superview) {
            NSView *bottomView = strongWindow.contentView.subviews.firstObject;
            if (bottomView != glassView && strongWindow.contentView.subviews.count > 1) {
                [glassView removeFromSuperview];
                [strongWindow.contentView addSubview:glassView positioned:NSWindowBelow relativeTo:strongWindow.contentView.subviews.firstObject];
                if (glassView.layer) glassView.layer.zPosition = -1000.0;
            }
            NSRect extendedFrame = NSInsetRect(strongWindow.contentView.bounds, -3, -3);
            if (!NSEqualRects(glassView.frame, extendedFrame)) {
                glassView.frame = extendedFrame;
                if (glassView.layer) {
                    glassView.layer.cornerRadius = 12.0;
                    glassView.layer.masksToBounds = YES;
                }
            }
        }
        END_NO_ANIMATION
    }];
    
    windowTimers[key] = timer;
    NSLog(@"[AeroFinder] Started background hiding timer for window");

    // Attach display link for per-frame background pruning during active animations
    NSValue *existingLinkValue = windowDisplayLinks[key];
    if (!existingLinkValue) {
        CVDisplayLinkRef link = NULL;
        CVReturn linkResult = CVDisplayLinkCreateWithActiveCGDisplays(&link);
        if (linkResult == kCVReturnSuccess && link) {
            CVDisplayLinkSetOutputCallback(link, displayLinkCallback, (__bridge void *)window);
            CVDisplayLinkStart(link);
            windowDisplayLinks[key] = [NSValue valueWithPointer:link];
            NSLog(@"[AeroFinder] Attached display link for window %p", window);
        } else if (link) {
            CVDisplayLinkRelease(link);
        }
    }
}

// Process titlebar/toolbar area for immediate transparency
static void processTitlebarArea(NSWindow *window) {
    if (!window) return;
    
    // Process the entire window view hierarchy, not just contentView
    // The titlebar is typically a sibling or parent of contentView
    NSView *contentView = window.contentView;
    if (contentView && contentView.superview) {
        NSView *parentView = contentView.superview;
        hideVisualEffectViews(parentView);
        makeTransparent(parentView);
        fixSidebarTitlebarViews(parentView);
        
        // Also process any titlebar accessory views
        if ([window respondsToSelector:@selector(titlebarAccessoryViewControllers)]) {
            NSArray *accessories = [window performSelector:@selector(titlebarAccessoryViewControllers)];
            for (id accessory in accessories) {
                if ([accessory respondsToSelector:@selector(view)]) {
                    NSView *accessoryView = [accessory performSelector:@selector(view)];
                    if (accessoryView) {
                        hideVisualEffectViews(accessoryView);
                        makeTransparent(accessoryView);
                    }
                }
            }
        }
    }
}

// Apply glass effect to window
static void applyGlassEffect(NSWindow *window) {
    if (!window || !shouldModifyWindow(window) || !glassAvailable) return;
    
    // CRITICAL: Make window transparent FIRST, before contentView processing
    setWindowTransparent(window);
    
    // Process titlebar/toolbar area immediately
    processTitlebarArea(window);
    
    NSView *contentView = window.contentView;
    if (!contentView) return;
    
    // Get or create glass view
    NSNumber *key = @((uintptr_t)window);
    NSView *glassView = glassViews[key];
    
    if (!glassView) {
        Class glassClass = NSClassFromString(@"NSGlassEffectView");
        if (!glassClass) return;
        
        // MINIMAL CORNER EXTENSION: Inset by -3 to cover just corners
        NSRect extendedFrame = NSInsetRect(contentView.bounds, -3, -3);
        glassView = [[glassClass alloc] initWithFrame:extendedFrame];
        setGlassStyleClear(glassView);
        
        glassView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        glassView.wantsLayer = YES;
        
        if (glassView.layer) {
            glassView.layer.cornerRadius = 12.0;  // Slightly larger for extended frame
            glassView.layer.masksToBounds = YES;
        }
        
        glassViews[key] = glassView;
        NSLog(@"[AeroFinder] Created NSGlassEffectView (clear style)");
    }
    
    // Hide all NSVisualEffectViews
    hideVisualEffectViews(contentView);
    
    // Make hierarchy transparent
    makeTransparent(contentView);
    
    // Fix sidebar titlebar views when applying glass effect
    fixSidebarTitlebarViews(contentView);
    
    // Add glass view to bottom
    if (!glassView.superview) {
        if (contentView.subviews.count > 0) {
            [contentView addSubview:glassView positioned:NSWindowBelow relativeTo:contentView.subviews.firstObject];
        } else {
            [contentView addSubview:glassView];
        }
        
        if (glassView.layer) {
            glassView.layer.zPosition = -1000.0;
        }
        
        NSLog(@"[AeroFinder] Added glass view to window");
    } else {
        // DYNAMIC ADAPTATION: Ensure glass stays at bottom when hierarchy changes
        NSView *bottomView = contentView.subviews.firstObject;
        if (bottomView != glassView && contentView.subviews.count > 1) {
            [glassView removeFromSuperview];
            [contentView addSubview:glassView positioned:NSWindowBelow relativeTo:contentView.subviews.firstObject];
            if (glassView.layer) {
                glassView.layer.zPosition = -1000.0;
            }
        }
    }
    
    // DYNAMIC ADAPTATION: Force glass frame to match content view bounds exactly
    NSRect extendedFrame = NSInsetRect(contentView.bounds, -3, -3);
    if (!NSEqualRects(glassView.frame, extendedFrame)) {
        BEGIN_NO_ANIMATION
        glassView.frame = extendedFrame;
        if (glassView.layer) {
            glassView.layer.cornerRadius = 12.0;
            glassView.layer.masksToBounds = YES;
        }
        END_NO_ANIMATION
    }
    
    // Start continuous background hiding timer
    startBackgroundHidingTimer(window);
}

// Remove glass effect
static void removeGlassEffect(NSWindow *window) {
    // Stop timer
    NSNumber *key = @((uintptr_t)window);
    NSTimer *timer = windowTimers[key];
    if (timer && timer.valid) {
        [timer invalidate];
        [windowTimers removeObjectForKey:key];
    }

    stopDisplayLinkForWindow(window);
    [windowMaintenanceTimestamps removeObjectForKey:key];
    
    if (!glassViews) return;
    
    NSView *glassView = glassViews[key];
    
    if (glassView) {
        [glassView removeFromSuperview];
        [glassViews removeObjectForKey:key];
    }
    
    window.backgroundColor = [NSColor windowBackgroundColor];
    window.opaque = YES;
}

// Update all windows
static void updateAllWindows(void) {
    for (NSWindow *window in [NSApplication sharedApplication].windows) {
        if (tweakEnabled) {
            applyGlassEffect(window);
        } else {
            removeGlassEffect(window);
        }
    }
}

#pragma mark - NSWindow Swizzles

ZKSwizzleInterface(_AeroFinder_NSWindow, NSWindow, NSObject)
@implementation _AeroFinder_NSWindow

- (void)close {
    // Clean up before closing to prevent crashes
    NSWindow *window = (NSWindow *)self;
    if (shouldModifyWindow(window)) {
        removeGlassEffect(window);
    }
    ZKOrig(void);
}

- (id)initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)flag {
    id result = ZKOrig(id, rect, style, backing, flag);
    if (result && tweakEnabled) {
        NSWindow *window = (NSWindow *)result;
        // Apply window transparency immediately, even before contentView is ready
        if ([NSThread isMainThread] && shouldModifyWindow(window)) {
            setWindowTransparent(window);
            processTitlebarArea(window);
            if (window.contentView) applyGlassEffect(window);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (shouldModifyWindow(window)) {
                    setWindowTransparent(window);
                    processTitlebarArea(window);
                    applyGlassEffect(window);
                }
            });
        }
    }
    return result;
}

- (void)orderFront:(id)sender {
    NSWindow *window = (NSWindow *)self;
    // Apply before ordering front to ensure effect is visible immediately
    if (tweakEnabled && shouldModifyWindow(window)) {
        applyGlassEffect(window);
    }
    ZKOrig(void, sender);
}

- (void)makeKeyAndOrderFront:(id)sender {
    NSWindow *window = (NSWindow *)self;
    // Apply before making key to ensure effect is visible immediately
    if (tweakEnabled && shouldModifyWindow(window)) {
        applyGlassEffect(window);
    }
    ZKOrig(void, sender);
}

- (void)becomeKeyWindow {
    NSWindow *window = (NSWindow *)self;
    // Ensure effect is applied when window becomes key
    if (tweakEnabled && shouldModifyWindow(window)) {
        applyGlassEffect(window);
    }
    ZKOrig(void);
}

- (void)setContentView:(NSView *)contentView {
    ZKOrig(void, contentView);
    NSWindow *window = (NSWindow *)self;
    // Apply immediately since we're already on main thread during window setup
    if (tweakEnabled && shouldModifyWindow(window)) {
        setWindowTransparent(window);
        processTitlebarArea(window);
        applyGlassEffect(window);
    }
}

- (void)setFrame:(NSRect)frameRect display:(BOOL)flag {
    NSWindow *window = (NSWindow *)self;
    
    if (tweakEnabled && shouldModifyWindow(window)) {
        BEGIN_NO_ANIMATION
        setWindowTransparent(window);
        END_NO_ANIMATION
    }
    
    ZKOrig(void, frameRect, flag);
    
    if (tweakEnabled && shouldModifyWindow(window)) {
        // DYNAMIC ADAPTATION: Update glass layer when window frame changes
        NSNumber *key = @((uintptr_t)window);
        NSView *glassView = glassViews[key];
        if (glassView && glassView.superview && window.contentView) {
            BEGIN_NO_ANIMATION
            NSRect extendedFrame = NSInsetRect(window.contentView.bounds, -3, -3);
            glassView.frame = extendedFrame;
            if (glassView.layer) {
                glassView.layer.cornerRadius = 12.0;
                glassView.layer.masksToBounds = YES;
            }
            setWindowTransparent(window);
            dispatch_async(dispatch_get_main_queue(), ^{
                forceHideBackgrounds(window.contentView);
            });
            END_NO_ANIMATION
        }
    }
}

- (void)setBackgroundColor:(NSColor *)color {
    NSWindow *window = (NSWindow *)self;
    if (tweakEnabled && shouldModifyWindow(window)) {
        ZKOrig(void, [NSColor clearColor]);
    } else {
        ZKOrig(void, color);
    }
}

- (void)setOpaque:(BOOL)opaque {
    NSWindow *window = (NSWindow *)self;
    if (tweakEnabled && shouldModifyWindow(window)) {
        ZKOrig(void, NO);
    } else {
        ZKOrig(void, opaque);
    }
}

- (void)setStyleMask:(NSWindowStyleMask)styleMask {
    NSWindow *window = (NSWindow *)self;
    BOOL wasFullscreen = isWindowFullscreen(window);
    
    ZKOrig(void, styleMask);
    
    if (!tweakEnabled || !isFinderProcess() || !window) return;
    
    BOOL isFullscreen = isWindowFullscreen(window);
    
    if (!wasFullscreen && isFullscreen) {
        removeGlassEffect(window);
        window.backgroundColor = [NSColor windowBackgroundColor];
        window.opaque = YES;
    } else if (wasFullscreen && !isFullscreen) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!shouldModifyWindow(window)) return;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!window || isWindowFullscreen(window) || !shouldModifyWindow(window)) return;
                applyGlassEffect(window);
            });
        });
    }
}

// Helper for live resize transparency
static void handleLiveResize(NSWindow *window) {
    BEGIN_NO_ANIMATION
    setWindowTransparent(window);
    dispatch_async(dispatch_get_main_queue(), ^{
        forceHideBackgrounds(window.contentView);
    });
    END_NO_ANIMATION
}

- (void)viewWillStartLiveResize {
    NSWindow *window = (NSWindow *)self;
    if (tweakEnabled && shouldModifyWindow(window)) handleLiveResize(window);
    ZKOrig(void);
}

- (void)viewDidEndLiveResize {
    NSWindow *window = (NSWindow *)self;
    if (tweakEnabled && shouldModifyWindow(window)) handleLiveResize(window);
    ZKOrig(void);
}

@end

#pragma mark - NSClipView Swizzles

ZKSwizzleInterface(_AeroFinder_NSClipView, NSClipView, NSObject)
@implementation _AeroFinder_NSClipView

- (void)setBoundsOrigin:(NSPoint)newOrigin {
    NSClipView *clipView = (NSClipView *)self;
    if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window)) {
        BEGIN_NO_ANIMATION
        ensureTransparentScrollStack((NSScrollView *)clipView.superview);
        END_NO_ANIMATION
    }
    ZKOrig(void, newOrigin);
}

- (void)setNeedsDisplay:(BOOL)flag {
    NSClipView *clipView = (NSClipView *)self;
    if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window)) {
        return; // Don't trigger display
    }
    
    ZKOrig(void, flag);
}

- (void)setNeedsDisplayInRect:(NSRect)rect {
    NSClipView *clipView = (NSClipView *)self;
    if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window)) {
        return; // Don't trigger display
    }
    
    ZKOrig(void, rect);
}

- (void)scrollToPoint:(NSPoint)newOrigin {
    NSClipView *clipView = (NSClipView *)self;
    if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window)) {
        BEGIN_NO_ANIMATION
        ensureTransparentScrollStack((NSScrollView *)clipView.superview);
        END_NO_ANIMATION
    }
    ZKOrig(void, newOrigin);
}

@end

#pragma mark - NSScrollView Swizzles

ZKSwizzleInterface(_AeroFinder_NSScrollView, NSScrollView, NSObject)
@implementation _AeroFinder_NSScrollView

- (void)reflectScrolledClipView:(NSClipView *)clipView {
    ZKOrig(void, clipView);
    NSScrollView *scrollView = (NSScrollView *)self;
    if (tweakEnabled && scrollView.window && shouldModifyWindow(scrollView.window)) {
        BEGIN_NO_ANIMATION
        ensureTransparentScrollStack(scrollView);
        END_NO_ANIMATION
    }
}

- (void)tile {
    NSScrollView *scrollView = (NSScrollView *)self;
    if (tweakEnabled && scrollView.window && shouldModifyWindow(scrollView.window)) {
        BEGIN_NO_ANIMATION
        ensureTransparentScrollStack(scrollView);
        END_NO_ANIMATION
    }
    ZKOrig(void);
}

- (void)setNeedsDisplay:(BOOL)flag {
    NSScrollView *scrollView = (NSScrollView *)self;
    if (tweakEnabled && scrollView.window && shouldModifyWindow(scrollView.window)) {
        return; // Don't trigger display
    }
    
    ZKOrig(void, flag);
}

- (void)setNeedsDisplayInRect:(NSRect)rect {
    NSScrollView *scrollView = (NSScrollView *)self;
    if (tweakEnabled && scrollView.window && shouldModifyWindow(scrollView.window)) {
        return; // Don't trigger display
    }
    
    ZKOrig(void, rect);
}

- (void)layout {
    ZKOrig(void);
    NSView *view = (NSView *)self;
    if (!tweakEnabled || !view.window || !shouldModifyWindow(view.window)) return;
    
    // Only process if this is the content view
    if (view != view.window.contentView) return;
    
    NSNumber *key = @((uintptr_t)view.window);
    NSView *glassView = glassViews[key];
    if (!glassView || !glassView.superview) return;
    
    NSRect extendedFrame = NSInsetRect(view.bounds, -3, -3);
    BOOL needsFrameUpdate = !NSEqualRects(glassView.frame, extendedFrame);
    BOOL needsRepositioning = (view.subviews.firstObject != glassView && view.subviews.count > 1);
    
    if (needsFrameUpdate || needsRepositioning) {
        BEGIN_NO_ANIMATION
        if (needsFrameUpdate) {
            glassView.frame = extendedFrame;
            if (glassView.layer) {
                glassView.layer.cornerRadius = 12.0;
                glassView.layer.masksToBounds = YES;
            }
        }
        if (needsRepositioning) {
            [glassView removeFromSuperview];
            [view addSubview:glassView positioned:NSWindowBelow relativeTo:view.subviews.firstObject];
            if (glassView.layer) glassView.layer.zPosition = -1000.0;
        }
        END_NO_ANIMATION
    }
}

@end

#pragma mark - Constructor

__attribute__((constructor))
static void initAeroFinder(void) {
    @autoreleasepool {
        if (!isFinderProcess()) {
            NSLog(@"[AeroFinder] Not Finder - skipping");
            return;
        }
        
        if (!checkGlassAvailability()) {
            NSLog(@"[AeroFinder] NSGlassEffectView not available (requires macOS 26.0+)");
            return;
        }
        
        glassViews = [NSMutableDictionary dictionary];
        windowTimers = [NSMutableDictionary dictionary];
        windowMaintenanceTimestamps = [NSMutableDictionary dictionary];
        windowDisplayLinks = [NSMutableDictionary dictionary];
        windowScrollTimestamps = [NSMutableDictionary dictionary];
        
        NSLog(@"[AeroFinder] Initializing glass effect tweak");
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), 
                      dispatch_get_main_queue(), ^{
            updateAllWindows();
        });
    }
}