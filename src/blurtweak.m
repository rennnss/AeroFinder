@import Foundation;
@import AppKit;
@import QuartzCore;
@import CoreVideo;
#import <objc/runtime.h>
#import "../ZKSwizzle/ZKSwizzle.h"

/**
 * AeroFinder - Finder Glass Effect Tweak (Merged v2.2 - Grouped Swizzling)
 *
 * IMPLEMENTATION:
 * - Hides Finder's background by removing/hiding NSVisualEffectView
 * - Adds NSGlassEffectView with .clear style to navigation windows
 * - Handles Sidebar and Titlebar artifacts
 * - Smart Fullscreen and Focus handling
 * - Uses ZKSwizzleInterfaceGroup for safe, process-isolated injection
 *
 * REQUIREMENTS:
 * - macOS 26.0+ for NSGlassEffectView
 * - Finder-only injection
 */

#pragma mark - Configuration

static BOOL tweakEnabled = YES;
static BOOL glassAvailable = NO;
static NSMutableDictionary *glassViews = nil;
static NSMutableDictionary *windowTimers = nil;
static NSMutableDictionary<NSNumber *, NSNumber *> *windowMaintenanceTimestamps = nil;
static NSMutableDictionary<NSNumber *, NSValue *> *windowDisplayLinks = nil;
static NSMutableDictionary<NSNumber *, NSNumber *> *windowScrollTimestamps = nil;
static NSColor *clearColorCache = nil;
static const NSTimeInterval kWindowMaintenanceInterval = 0.018;
static const NSTimeInterval kScrollActivityWindow = 0.5;

#pragma mark - Macros

#define BEGIN_NO_ANIMATION \
    [CATransaction begin]; \
    [CATransaction setDisableActions:YES]; \
    [CATransaction setAnimationDuration:0];

#define END_NO_ANIMATION [CATransaction commit];

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

// Forward declarations
static inline void ensureTransparentScrollStack(NSScrollView *scrollView);
static void refreshScrollStacksInView(NSView *view, NSInteger depth);
static void refreshScrollStacksForWindow(NSWindow *window);
static void stopDisplayLinkForWindow(NSWindow *window);
static CVReturn displayLinkCallback(CVDisplayLinkRef link, const CVTimeStamp *inNow, const CVTimeStamp *inOutputTime, CVOptionFlags flagsIn, CVOptionFlags *flagsOut, void *displayLinkContext);
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

// Check if window should be modified
static inline BOOL shouldModifyWindow(NSWindow *window) {
    if (!window || !tweakEnabled || !isFinderProcess()) return NO;
    
    // EXCLUDE: Fullscreen windows
    if (isWindowFullscreen(window)) return NO;
    
    // EXCLUDE: TGoToWindowController and related windows
    NSString *windowClassName = NSStringFromClass([window class]);
    if ([windowClassName isEqualToString:@"TGoToWindowController"]) return NO;
    if ([windowClassName containsString:@"TGoToWindow"]) return NO;
    if ([windowClassName containsString:@"GoToWindow"]) return NO;
    
    // EXCLUDE: QuickLook windows
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
    
    // Check window title
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
    NSString *className = NSStringFromClass([view class]);
    if ([className containsString:@"QL"] || [className containsString:@"QuickLook"] ||
        [className containsString:@"Web"] || [className containsString:@"WebKit"]) return YES;
    
    NSView *current = view;
    while (current) {
        NSString *currentClassName = NSStringFromClass([current class]);
        if ([currentClassName containsString:@"QL"] || [currentClassName containsString:@"QuickLook"] ||
            [currentClassName containsString:@"Web"] || [currentClassName containsString:@"WebKit"]) return YES;
        current = current.superview;
    }
    return NO;
}

// Hide all NSVisualEffectView in hierarchy
static void hideVisualEffectViews(NSView *view) {
    if (!view) return;
    if (isQuickLookOrWebKitView(view)) return;
    if (view.window && !shouldModifyWindow(view.window)) return;
    
    for (NSView *subview in [view.subviews copy]) {
        if ([subview isKindOfClass:[NSVisualEffectView class]]) {
            subview.hidden = YES;
            subview.alphaValue = 0.0;
        }
        hideVisualEffectViews(subview);
    }
}

// Remove known Finder background wrappers
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
        if ([subview isKindOfClass:[NSScrollView class]] || [subview isKindOfClass:[NSClipView class]]) {
            continue;
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

static inline BOOL isWindowScrolling(NSWindow *window) {
    if (!window || !windowScrollTimestamps) return NO;
    NSNumber *key = @((uintptr_t)window);
    NSNumber *lastScroll = windowScrollTimestamps[key];
    if (!lastScroll) return NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    return (now - lastScroll.doubleValue) < kScrollActivityWindow;
}

// Lightweight refresh for scroll stacks
static inline void ensureTransparentScrollStack(NSScrollView *scrollView) {
    if (!scrollView) return;
    if (isQuickLookOrWebKitView(scrollView)) return;
    NSColor *clear = getClearColor();
    
    if (scrollView.window) {
        markWindowScrolling(scrollView.window);
    }
    
    void (^applyTransparency)(NSView *) = ^(NSView *view) {
        if (!view || isQuickLookOrWebKitView(view)) return;
        if (!view.wantsLayer) view.wantsLayer = YES;
        
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
        
        BOOL isBackgroundView = ([view isKindOfClass:[NSVisualEffectView class]] ||
                                [className isEqualToString:@"NSTitlebarBackgroundView"] ||
                                [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
                                [className isEqualToString:@"BackdropView"] ||
                                [className hasSuffix:@"BackgroundView"]);
        
        if (isBackgroundView) {
            if (view.layer || view.wantsLayer) {
                if (!view.wantsLayer) view.wantsLayer = YES;
                view.layer.opacity = 0.0;
                view.layer.backgroundColor = [[NSColor clearColor] CGColor];
                if ([view isKindOfClass:[NSVisualEffectView class]]) {
                    view.hidden = YES;
                }
            }
            if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
                @try { [(id)view setDrawsBackground:NO]; } @catch (NSException *e) {}
            }
        } else {
            if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
                @try { [(id)view setDrawsBackground:NO]; } @catch (NSException *e) {}
            }
        }
    };
    
    applyTransparency(scrollView);
    NSClipView *clipView = scrollView.contentView;
    applyTransparency(clipView);
    
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
            NSArray *allSubviews = [documentView.subviews copy];
            for (NSView *subview in allSubviews) {
                NSString *subviewClass = NSStringFromClass([subview class]);
                if ([subview isKindOfClass:[NSVisualEffectView class]] ||
                    [subviewClass hasSuffix:@"BackgroundView"] ||
                    [subviewClass isEqualToString:@"BackdropView"]) {
                    hideBackgroundLayer(subview);
                }
                applyTransparency(subview);
            }
        }
    }
}

// Recursive background removal
static void forceHideBackgrounds(NSView *view) {
    if (!view) return;
    if (isQuickLookOrWebKitView(view)) return;
    if (view.window && !shouldModifyWindow(view.window)) return;
    
    if (!view.wantsLayer) view.wantsLayer = YES;
    
    NSArray *subviews = [view.subviews copy];
    for (NSView *subview in subviews) {
        if (isQuickLookOrWebKitView(subview)) continue;
        if (!subview.wantsLayer) subview.wantsLayer = YES;
        
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

static CVReturn displayLinkCallback(CVDisplayLinkRef link, const CVTimeStamp *inNow, const CVTimeStamp *inOutputTime, CVOptionFlags flagsIn, CVOptionFlags *flagsOut, void *displayLinkContext) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)displayLinkContext;
        if (!window) return kCVReturnSuccess;
        __weak NSWindow *weakWindow = window;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSWindow *strongWindow = weakWindow;
            if (!tweakEnabled || !strongWindow || !strongWindow.contentView) return;
            if (!shouldModifyWindow(strongWindow)) return;
            
            NSNumber *key = @((uintptr_t)strongWindow);
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            NSNumber *lastMaintenance = windowMaintenanceTimestamps[key];
            if (lastMaintenance && (now - lastMaintenance.doubleValue) < kWindowMaintenanceInterval) return;
            
            windowMaintenanceTimestamps[key] = @(now);
            refreshScrollStacksForWindow(strongWindow);
        });
    }
    return kCVReturnSuccess;
}

// Fix sidebar titlebar views
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
    if (isQuickLookOrWebKitView(view)) return;
    if (view.window && !shouldModifyWindow(view.window)) return;
    if ([view isKindOfClass:NSClassFromString(@"NSGlassEffectView")]) return;
    
    if ([view isKindOfClass:[NSVisualEffectView class]]) {
        view.hidden = YES;
        view.alphaValue = 0.0;
        return;
    }
    
    if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
        @try { [(id)view setDrawsBackground:NO]; } @catch (NSException *e) {}
    }
    NSColor *clear = getClearColor();
    if ([view respondsToSelector:@selector(setBackgroundColor:)]) {
        @try { [(id)view setBackgroundColor:clear]; } @catch (NSException *e) {}
    }
    
    for (NSView *subview in [view.subviews copy]) {
        makeTransparent(subview);
    }
}

// Process titlebar/toolbar area
static void processTitlebarArea(NSWindow *window) {
    if (!window) return;
    
    NSView *contentView = window.contentView;
    if (contentView && contentView.superview) {
        NSView *parentView = contentView.superview;
        hideVisualEffectViews(parentView);
        makeTransparent(parentView);
        fixSidebarTitlebarViews(parentView);
        
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

static void startBackgroundHidingTimer(NSWindow *window) {
    if (!window) return;

    if (!windowTimers) windowTimers = [NSMutableDictionary dictionary];
    if (!windowMaintenanceTimestamps) windowMaintenanceTimestamps = [NSMutableDictionary dictionary];
    if (!windowDisplayLinks) windowDisplayLinks = [NSMutableDictionary dictionary];

    NSNumber *key = @((uintptr_t)window);
    __weak NSWindow *weakWindow = window;

    NSTimer *existingTimer = windowTimers[key];
    if (existingTimer && existingTimer.valid) {
        [existingTimer invalidate];
    }
    
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.033 repeats:YES block:^(NSTimer *timer) {
        NSWindow *strongWindow = weakWindow;
        if (!strongWindow || !strongWindow.contentView || !shouldModifyWindow(strongWindow)) {
            [timer invalidate];
            stopDisplayLinkForKey(key);
            [windowTimers removeObjectForKey:key];
            [windowMaintenanceTimestamps removeObjectForKey:key];
            return;
        }

        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        NSNumber *maintenanceKey = @((uintptr_t)strongWindow);
        NSNumber *lastMaintenance = windowMaintenanceTimestamps[maintenanceKey];
        if (lastMaintenance && (now - lastMaintenance.doubleValue) < kWindowMaintenanceInterval) return;
        windowMaintenanceTimestamps[maintenanceKey] = @(now);
        
        BEGIN_NO_ANIMATION
        setWindowTransparent(strongWindow);
        processTitlebarArea(strongWindow);
        
        if (isWindowScrolling(strongWindow)) {
            refreshScrollStacksForWindow(strongWindow);
        }
        
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
    
    NSValue *existingLinkValue = windowDisplayLinks[key];
    if (!existingLinkValue) {
        CVDisplayLinkRef link = NULL;
        CVReturn linkResult = CVDisplayLinkCreateWithActiveCGDisplays(&link);
        if (linkResult == kCVReturnSuccess && link) {
            CVDisplayLinkSetOutputCallback(link, displayLinkCallback, (__bridge void *)window);
            CVDisplayLinkStart(link);
            windowDisplayLinks[key] = [NSValue valueWithPointer:link];
        } else if (link) {
            CVDisplayLinkRelease(link);
        }
    }
}

static void applyGlassEffect(NSWindow *window) {
    if (!shouldModifyWindow(window) || !glassAvailable) return;
    
    setWindowTransparent(window);
    processTitlebarArea(window);
    
    NSView *contentView = window.contentView;
    if (!contentView) return;
    
    NSNumber *key = @((uintptr_t)window);
    NSView *glassView = glassViews[key];
    
    if (!glassView) {
        Class glassClass = NSClassFromString(@"NSGlassEffectView");
        if (!glassClass) return;
        
        NSRect extendedFrame = NSInsetRect(contentView.bounds, -3, -3);
        glassView = [[glassClass alloc] initWithFrame:extendedFrame];
        setGlassStyleClear(glassView);
        glassView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        glassView.wantsLayer = YES;
        if (glassView.layer) {
            glassView.layer.cornerRadius = 12.0;
            glassView.layer.masksToBounds = YES;
        }
        glassViews[key] = glassView;
        NSLog(@"[AeroFinder] Created NSGlassEffectView (clear style)");
    }
    
    hideVisualEffectViews(contentView);
    makeTransparent(contentView);
    fixSidebarTitlebarViews(contentView);
    
    if (!glassView.superview) {
        if (contentView.subviews.count > 0) {
            [contentView addSubview:glassView positioned:NSWindowBelow relativeTo:contentView.subviews.firstObject];
        } else {
            [contentView addSubview:glassView];
        }
        if (glassView.layer) glassView.layer.zPosition = -1000.0;
    } else {
        NSView *bottomView = contentView.subviews.firstObject;
        if (bottomView != glassView && contentView.subviews.count > 1) {
            [glassView removeFromSuperview];
            [contentView addSubview:glassView positioned:NSWindowBelow relativeTo:contentView.subviews.firstObject];
            if (glassView.layer) glassView.layer.zPosition = -1000.0;
        }
    }
    
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
    
    startBackgroundHidingTimer(window);
}

static void removeGlassEffect(NSWindow *window) {
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

static void updateAllWindows(void) {
    for (NSWindow *window in [NSApplication sharedApplication].windows) {
        if (tweakEnabled) applyGlassEffect(window);
        else removeGlassEffect(window);
    }
}

#pragma mark - NSWindow Swizzles

// Swizzles are grouped under "AeroFinderGroup" and NOT applied at +load
ZKSwizzleInterfaceGroup(_AeroFinder_NSWindow, NSWindow, NSObject, AeroFinderGroup)
@implementation _AeroFinder_NSWindow

- (void)close {
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
        // V1 Safe Logic: Delay application until runloop settles
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), 
                      dispatch_get_main_queue(), ^{
            if (window && window.contentView && shouldModifyWindow(window)) {
                applyGlassEffect(window);
            }
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

- (void)makeKeyAndOrderFront:(id)sender {
    NSWindow *window = (NSWindow *)self;
    if (tweakEnabled && shouldModifyWindow(window)) {
        applyGlassEffect(window);
    }
    ZKOrig(void, sender);
}

- (void)becomeKeyWindow {
    NSWindow *window = (NSWindow *)self;
    if (tweakEnabled && shouldModifyWindow(window)) {
        applyGlassEffect(window);
    }
    ZKOrig(void);
}

- (void)setContentView:(NSView *)contentView {
    ZKOrig(void, contentView);
    NSWindow *window = (NSWindow *)self;
    if (tweakEnabled && shouldModifyWindow(window)) {
        // V1 Safe Logic: Wait for content view layout
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), 
                      dispatch_get_main_queue(), ^{
            if (window && window.contentView && shouldModifyWindow(window)) {
                applyGlassEffect(window);
            }
        });
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

ZKSwizzleInterfaceGroup(_AeroFinder_NSClipView, NSClipView, NSObject, AeroFinderGroup)
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
    if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window)) return;
    ZKOrig(void, flag);
}

- (void)setNeedsDisplayInRect:(NSRect)rect {
    NSClipView *clipView = (NSClipView *)self;
    if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window)) return;
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

ZKSwizzleInterfaceGroup(_AeroFinder_NSScrollView, NSScrollView, NSObject, AeroFinderGroup)
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
    if (tweakEnabled && scrollView.window && shouldModifyWindow(scrollView.window)) return;
    ZKOrig(void, flag);
}

- (void)setNeedsDisplayInRect:(NSRect)rect {
    NSScrollView *scrollView = (NSScrollView *)self;
    if (tweakEnabled && scrollView.window && shouldModifyWindow(scrollView.window)) return;
    ZKOrig(void, rect);
}

- (void)layout {
    ZKOrig(void);
    NSView *view = (NSView *)self;
    if (!tweakEnabled || !view.window || !shouldModifyWindow(view.window)) return;
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
        // 1. PROCESS CHECK
        if (!isFinderProcess()) {
            NSLog(@"[AeroFinder] Not Finder - skipping");
            return;
        }
        
        // 2. CAPABILITY CHECK
        if (!checkGlassAvailability()) {
            NSLog(@"[AeroFinder] NSGlassEffectView not available (requires macOS 26.0+)");
            return;
        }
        
        // 3. INITIALIZATION
        glassViews = [NSMutableDictionary dictionary];
        windowTimers = [NSMutableDictionary dictionary];
        windowMaintenanceTimestamps = [NSMutableDictionary dictionary];
        windowDisplayLinks = [NSMutableDictionary dictionary];
        windowScrollTimestamps = [NSMutableDictionary dictionary];
        
        NSLog(@"[AeroFinder] Initializing glass effect tweak (Merged v2.2 Group)");
        
        // 4. ACTIVATE SWIZZLES
        // Only activate now that we know we are safely inside Finder
        ZKSwizzleGroup(AeroFinderGroup);
        
        // 5. UPDATE EXISTING WINDOWS
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), 
                      dispatch_get_main_queue(), ^{
            updateAllWindows();
        });
    }
}
