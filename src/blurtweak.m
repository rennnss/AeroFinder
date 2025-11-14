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

// Check if window should be modified
static inline BOOL shouldModifyWindow(NSWindow *window) {
    if (!window || !tweakEnabled || !isFinderProcess()) return NO;
    
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
        if ([subview respondsToSelector:@selector(setBackgroundColor:)]) {
            if (!clearColorCache) {
                clearColorCache = [NSColor clearColor];
            }
            @try { [(id)subview setBackgroundColor:clearColorCache]; } @catch (NSException *e) {}
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
    if (!clearColorCache) {
        clearColorCache = [NSColor clearColor];
    }
    
    // Mark window as scrolling for aggressive cleanup
    if (scrollView.window) {
        markWindowScrolling(scrollView.window);
    }
    
    void (^applyTransparency)(NSView *) = ^(NSView *view) {
        if (!view || isQuickLookOrWebKitView(view)) return;
        if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [(id)view setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        if ([view respondsToSelector:@selector(setBackgroundColor:)]) {
            @try { [(id)view setBackgroundColor:clearColorCache]; } @catch (NSException *e) {}
        }
        if (view.layer) {
            view.layer.backgroundColor = [clearColorCache CGColor];
            view.layer.opaque = NO;
        }
    };
    
    void (^hideBackgroundLayer)(NSView *) = ^(NSView *view) {
        if (!view || isQuickLookOrWebKitView(view)) return;
        // Use layer opacity for instant background hiding during scroll
        if (view.wantsLayer || view.layer) {
            if (!view.wantsLayer) view.wantsLayer = YES;
            if ([view isKindOfClass:[NSVisualEffectView class]]) {
                view.layer.opacity = 0.0;
                view.hidden = YES;
            }
            NSString *className = NSStringFromClass([view class]);
            if ([className containsString:@"Background"] || [className containsString:@"Backdrop"]) {
                view.layer.opacity = 0.0;
            }
        }
    };
    
    applyTransparency(scrollView);
    NSClipView *clipView = scrollView.contentView;
    applyTransparency(clipView);
    
    // Fast layer-based hiding for backgrounds
    for (NSView *subview in scrollView.subviews) {
        hideBackgroundLayer(subview);
    }
    for (NSView *subview in clipView.subviews) {
        hideBackgroundLayer(subview);
    }
    
    if ([clipView isKindOfClass:[NSClipView class]]) {
        NSView *documentView = clipView.documentView;
        if ([documentView isKindOfClass:[NSVisualEffectView class]]) {
            hideBackgroundLayer(documentView);
        } else {
            applyTransparency(documentView);
            for (NSView *subview in documentView.subviews) {
                hideBackgroundLayer(subview);
            }
        }
    }
}

// Comprehensive but throttled background removal (called sparingly)
static void forceHideBackgrounds(NSView *view) {
    if (!view) return;
    if (isQuickLookOrWebKitView(view)) return;
    if (view.window && !shouldModifyWindow(view.window)) return;
    NSArray *subviews = [view.subviews copy];
    for (NSView *subview in subviews) {
        if (isQuickLookOrWebKitView(subview)) continue;
        NSString *className = NSStringFromClass([subview class]);
        BOOL isBackgroundClass = ([subview isKindOfClass:[NSVisualEffectView class]] ||
                                  [className isEqualToString:@"NSTitlebarBackgroundView"] ||
                                  [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
                                  [className isEqualToString:@"BackdropView"]);
        if (isBackgroundClass) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [subview removeFromSuperview];
            });
            continue;
        }
        if ([subview respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [(id)subview setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        if ([subview respondsToSelector:@selector(setBackgroundColor:)]) {
            if (!clearColorCache) {
                clearColorCache = [NSColor clearColor];
            }
            @try { [(id)subview setBackgroundColor:clearColorCache]; } @catch (NSException *e) {}
        }
        if (subview.layer) {
            subview.layer.backgroundColor = [clearColorCache CGColor];
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
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!tweakEnabled || !window.contentView) return;
            if (!shouldModifyWindow(window)) return;
            NSNumber *key = @((uintptr_t)window);
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            NSNumber *lastMaintenance = windowMaintenanceTimestamps[key];
            if (lastMaintenance && (now - lastMaintenance.doubleValue) < kWindowMaintenanceInterval) {
                return;
            }
            windowMaintenanceTimestamps[key] = @(now);
            refreshScrollStacksForWindow(window);
        });
    }
    return kCVReturnSuccess;
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
    
    if (!clearColorCache) {
        clearColorCache = [NSColor clearColor];
    }
    
    if ([view respondsToSelector:@selector(setBackgroundColor:)]) {
        @try { [(id)view setBackgroundColor:clearColorCache]; } @catch (NSException *e) {}
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
        
        // CRITICAL: Check if window should still be modified
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
        
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        
        if (!clearColorCache) {
            clearColorCache = [NSColor clearColor];
        }
        strongWindow.backgroundColor = clearColorCache;
        strongWindow.opaque = NO;
        
        // Only do heavy background hiding if window is actively scrolling
        BOOL scrolling = isWindowScrolling(strongWindow);
        if (scrolling) {
            // Aggressive cleanup during scroll
            refreshScrollStacksForWindow(strongWindow);
        }
        
        // DYNAMIC ADAPTATION: Keep glass layer at bottom and sized correctly
        NSView *glassView = glassViews[key];
        if (glassView && glassView.superview) {
            // Ensure glass is at bottom of view hierarchy
            NSView *bottomView = strongWindow.contentView.subviews.firstObject;
            if (bottomView != glassView && strongWindow.contentView.subviews.count > 1) {
                [glassView removeFromSuperview];
                [strongWindow.contentView addSubview:glassView positioned:NSWindowBelow relativeTo:strongWindow.contentView.subviews.firstObject];
                if (glassView.layer) {
                    glassView.layer.zPosition = -1000.0;
                }
            }
            
            // Dynamically adapt frame to content view bounds
            NSRect extendedFrame = NSInsetRect(strongWindow.contentView.bounds, -3, -3);
            if (!NSEqualRects(glassView.frame, extendedFrame)) {
                glassView.frame = extendedFrame;
                if (glassView.layer) {
                    glassView.layer.cornerRadius = 12.0;
                    glassView.layer.masksToBounds = YES;
                }
            }
        }
        
        [CATransaction commit];
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

// Apply glass effect to window
static void applyGlassEffect(NSWindow *window) {
    if (!shouldModifyWindow(window) || !glassAvailable) return;
    
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
    
    // Make window transparent
    if (!clearColorCache) {
        clearColorCache = [NSColor clearColor];
    }
    window.backgroundColor = clearColorCache;
    window.opaque = NO;
    
    // Hide all NSVisualEffectViews
    hideVisualEffectViews(contentView);
    
    // Make hierarchy transparent
    makeTransparent(contentView);
    
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
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        glassView.frame = extendedFrame;
        if (glassView.layer) {
            glassView.layer.cornerRadius = 12.0;
            glassView.layer.masksToBounds = YES;
        }
        [CATransaction commit];
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

- (id)initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)flag {
    id result = ZKOrig(id, rect, style, backing, flag);
    if (result && tweakEnabled) {
        NSWindow *window = (NSWindow *)result;
        dispatch_async(dispatch_get_main_queue(), ^{
            applyGlassEffect(window);
        });
    }
    return result;
}

- (void)orderFront:(id)sender {
    NSWindow *window = (NSWindow *)self;
    if (tweakEnabled && shouldModifyWindow(window)) {
        applyGlassEffect(window);
    }
    ZKOrig(void, sender);
}

- (void)setContentView:(NSView *)contentView {
    ZKOrig(void, contentView);
    NSWindow *window = (NSWindow *)self;
    if (tweakEnabled && shouldModifyWindow(window)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            applyGlassEffect(window);
        });
    }
}

- (void)setFrame:(NSRect)frameRect display:(BOOL)flag {
    NSWindow *window = (NSWindow *)self;
    
    if (tweakEnabled && shouldModifyWindow(window)) {
        // CRITICAL: Force transparency BEFORE resize to prevent opaque flash
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        
        if (!clearColorCache) {
            clearColorCache = [NSColor clearColor];
        }
        window.backgroundColor = clearColorCache;
        window.opaque = NO;
        
        [CATransaction commit];
    }
    
    ZKOrig(void, frameRect, flag);
    
    if (tweakEnabled && shouldModifyWindow(window)) {
        // DYNAMIC ADAPTATION: Update glass layer when window frame changes
        NSNumber *key = @((uintptr_t)window);
        NSView *glassView = glassViews[key];
        if (glassView && glassView.superview && window.contentView) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [CATransaction setAnimationDuration:0];
            
            NSRect extendedFrame = NSInsetRect(window.contentView.bounds, -3, -3);
            glassView.frame = extendedFrame;
            if (glassView.layer) {
                glassView.layer.cornerRadius = 12.0;
                glassView.layer.masksToBounds = YES;
            }
            
            // Force window transparency AFTER resize too
            window.backgroundColor = clearColorCache;
            window.opaque = NO;
            
            // Force hide backgrounds during resize
            dispatch_async(dispatch_get_main_queue(), ^{
                forceHideBackgrounds(window.contentView);
            });
            
            [CATransaction commit];
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

// CRITICAL: Intercept live resize start to maintain transparency
- (void)viewWillStartLiveResize {
    NSWindow *window = (NSWindow *)self;
    if (tweakEnabled && shouldModifyWindow(window)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        
        if (!clearColorCache) {
            clearColorCache = [NSColor clearColor];
        }
        window.backgroundColor = clearColorCache;
        window.opaque = NO;
        
        // Force hide backgrounds immediately
        dispatch_async(dispatch_get_main_queue(), ^{
            forceHideBackgrounds(window.contentView);
        });
        
        [CATransaction commit];
    }
    ZKOrig(void);
}

// CRITICAL: Intercept live resize end to ensure transparency is maintained
- (void)viewDidEndLiveResize {
    NSWindow *window = (NSWindow *)self;
    if (tweakEnabled && shouldModifyWindow(window)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        
        if (!clearColorCache) {
            clearColorCache = [NSColor clearColor];
        }
        window.backgroundColor = clearColorCache;
        window.opaque = NO;
        
        // Force hide backgrounds immediately
        dispatch_async(dispatch_get_main_queue(), ^{
            forceHideBackgrounds(window.contentView);
        });
        
        [CATransaction commit];
    }
    ZKOrig(void);
}

@end

#pragma mark - NSClipView Swizzles

ZKSwizzleInterface(_AeroFinder_NSClipView, NSClipView, NSObject)
@implementation _AeroFinder_NSClipView

- (void)setBoundsOrigin:(NSPoint)newOrigin {
    // CRITICAL: During scrolling bounds changes, force transparency
    NSClipView *clipView = (NSClipView *)self;
    if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        ensureTransparentScrollStack((NSScrollView *)clipView.superview);
        [CATransaction commit];
    }
    
    ZKOrig(void, newOrigin);
}

- (void)setNeedsDisplay:(BOOL)flag {
    NSClipView *clipView = (NSClipView *)self;
    
    // CRITICAL: Block display updates during scrolling for clip views in our windows
    if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window)) {
        return; // Don't trigger display
    }
    
    ZKOrig(void, flag);
}

- (void)setNeedsDisplayInRect:(NSRect)rect {
    NSClipView *clipView = (NSClipView *)self;
    
    // CRITICAL: Block display updates during scrolling for clip views in our windows
    if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window)) {
        return; // Don't trigger display
    }
    
    ZKOrig(void, rect);
}

- (void)scrollToPoint:(NSPoint)newOrigin {
    // CRITICAL: During scroll, force transparency
    NSClipView *clipView = (NSClipView *)self;
    if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        ensureTransparentScrollStack((NSScrollView *)clipView.superview);
        [CATransaction commit];
    }
    
    ZKOrig(void, newOrigin);
}

@end

#pragma mark - NSScrollView Swizzles

ZKSwizzleInterface(_AeroFinder_NSScrollView, NSScrollView, NSObject)
@implementation _AeroFinder_NSScrollView

- (void)reflectScrolledClipView:(NSClipView *)clipView {
    // CRITICAL: During scroll, force transparency to prevent background flicker
    NSScrollView *scrollView = (NSScrollView *)self;
    if (tweakEnabled && scrollView.window && shouldModifyWindow(scrollView.window)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        ensureTransparentScrollStack(scrollView);
        [CATransaction commit];
    }
    
    ZKOrig(void, clipView);
}

- (void)tile {
    // Intercept tile (layout) to force transparency
    NSScrollView *scrollView = (NSScrollView *)self;
    if (tweakEnabled && scrollView.window && shouldModifyWindow(scrollView.window)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        ensureTransparentScrollStack(scrollView);
        [CATransaction commit];
    }
    
    ZKOrig(void);
}

- (void)setNeedsDisplay:(BOOL)flag {
    NSScrollView *scrollView = (NSScrollView *)self;
    
    // CRITICAL: Block display updates for scroll views in our windows
    if (tweakEnabled && scrollView.window && shouldModifyWindow(scrollView.window)) {
        return; // Don't trigger display
    }
    
    ZKOrig(void, flag);
}

- (void)setNeedsDisplayInRect:(NSRect)rect {
    NSScrollView *scrollView = (NSScrollView *)self;
    
    // CRITICAL: Block display updates for scroll views in our windows
    if (tweakEnabled && scrollView.window && shouldModifyWindow(scrollView.window)) {
        return; // Don't trigger display
    }
    
    ZKOrig(void, rect);
}

- (void)layout {
    ZKOrig(void);
    
    // DYNAMIC ADAPTATION: Update glass layer when content view layout changes
    NSView *view = (NSView *)self;
    // Early exit if not enabled or not our window
    if (!tweakEnabled || !view.window || !shouldModifyWindow(view.window)) return;
    
    // Only process if this is the content view
    if (view != view.window.contentView) return;
    
    NSNumber *key = @((uintptr_t)view.window);
    NSView *glassView = glassViews[key];
    if (!glassView || !glassView.superview) return;
    
    NSRect extendedFrame = NSInsetRect(view.bounds, -3, -3);
    BOOL needsFrameUpdate = !NSEqualRects(glassView.frame, extendedFrame);
    BOOL needsRepositioning = (view.subviews.firstObject != glassView && view.subviews.count > 1);
    
    // Only update if something changed
    if (needsFrameUpdate || needsRepositioning) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        
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
            if (glassView.layer) {
                glassView.layer.zPosition = -1000.0;
            }
        }
        
        [CATransaction commit];
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