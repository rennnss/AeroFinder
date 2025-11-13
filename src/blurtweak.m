@import Foundation;
@import AppKit;
@import QuartzCore;
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
static NSMutableSet *blockedViews = nil;
static NSMutableDictionary *displayLinks = nil;
static NSColor *clearColorCache = nil;  // Performance: Cache clear color to avoid repeated allocations

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

// Check if window should be modified
static inline BOOL shouldModifyWindow(NSWindow *window) {
    if (!window || !tweakEnabled || !isFinderProcess()) return NO;
    
    // EXCLUDE: TGoToWindowController and related windows - never touch these
    NSString *windowClassName = NSStringFromClass([window class]);
    
    // Check window class name
    if ([windowClassName isEqualToString:@"TGoToWindowController"]) return NO;
    if ([windowClassName containsString:@"TGoToWindow"]) return NO;
    if ([windowClassName containsString:@"GoToWindow"]) return NO;
    
    // Check window controller class name
    if (window.windowController) {
        NSString *controllerClassName = NSStringFromClass([window.windowController class]);
        if ([controllerClassName isEqualToString:@"TGoToWindowController"]) return NO;
        if ([controllerClassName containsString:@"TGoToWindow"]) return NO;
        if ([controllerClassName containsString:@"GoToWindow"]) return NO;
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

// Hide all NSVisualEffectView in hierarchy
static void hideVisualEffectViews(NSView *view) {
    if (!view) return;
    
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
static void forceHideBackgrounds(NSView *view) {
    if (!view) return;
    
    // CRITICAL: Skip views from excluded windows
    if (view.window && !shouldModifyWindow(view.window)) return;
    
    // Cache class and do single check
    Class viewClass = [view class];
    
    // Track and remove NSVisualEffectView completely
    if ([view isKindOfClass:[NSVisualEffectView class]]) {
        @synchronized(blockedViews) {
            [blockedViews addObject:[NSValue valueWithNonretainedObject:view]];
        }
        [view removeFromSuperview];
        return;
    }
    
    // Get className only once if needed for string comparison
    NSString *className = NSStringFromClass(viewClass);
    
    // Track and remove known background views completely
    if ([className isEqualToString:@"NSTitlebarBackgroundView"] ||
        [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
        [className isEqualToString:@"BackdropView"]) {
        @synchronized(blockedViews) {
            [blockedViews addObject:[NSValue valueWithNonretainedObject:view]];
        }
        [view removeFromSuperview];
        return;
    }
    
    // Use cached clear color
    if (!clearColorCache) {
        clearColorCache = [NSColor clearColor];
    }
    
    // Force TScrollView transparency
    if ([className isEqualToString:@"TScrollView"]) {
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
    }
    
    // Force all NSScrollView subclasses to be transparent
    if ([view isKindOfClass:[NSScrollView class]]) {
        NSScrollView *scrollView = (NSScrollView *)view;
        if ([scrollView respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [scrollView setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        if ([scrollView respondsToSelector:@selector(setBackgroundColor:)]) {
            @try { [scrollView setBackgroundColor:clearColorCache]; } @catch (NSException *e) {}
        }
        if (scrollView.layer) {
            scrollView.layer.backgroundColor = [clearColorCache CGColor];
            scrollView.layer.opaque = NO;
        }
        
        // Force contentView transparency
        NSClipView *clipView = scrollView.contentView;
        if (clipView) {
            if ([clipView respondsToSelector:@selector(setDrawsBackground:)]) {
                @try { [clipView setDrawsBackground:NO]; } @catch (NSException *e) {}
            }
            if ([clipView respondsToSelector:@selector(setBackgroundColor:)]) {
                @try { [clipView setBackgroundColor:clearColorCache]; } @catch (NSException *e) {}
            }
            if (clipView.layer) {
                clipView.layer.backgroundColor = [clearColorCache CGColor];
                clipView.layer.opaque = NO;
            }
        }
    }
    
    // Force all NSClipView to be transparent (only if not already handled above)
    else if ([view isKindOfClass:[NSClipView class]]) {
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
    }
    
    // Recurse through all subviews (copy array since we're removing items)
    NSArray *subviews = [view.subviews copy];
    for (NSView *subview in subviews) {
        forceHideBackgrounds(subview);
    }
}

// Make view hierarchy transparent
static void makeTransparent(NSView *view) {
    if (!view) return;
    
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
    
    NSNumber *key = @((NSUInteger)window);
    
    // Cancel existing timer if any
    NSTimer *existingTimer = windowTimers[key];
    if (existingTimer && existingTimer.valid) {
        [existingTimer invalidate];
    }
    
    // Create timer at 300Hz for ultra-aggressive enforcement
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.0033  // 300fps
                                                      repeats:YES
                                                        block:^(NSTimer *timer) {
        if (!window || !window.contentView) {
            [timer invalidate];
            return;
        }
        
        // CRITICAL: Check if window should still be modified
        if (!shouldModifyWindow(window)) {
            [timer invalidate];
            return;
        }
        
        // ULTRA-AGGRESSIVE: Force window transparency every frame
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        
        if (!clearColorCache) {
            clearColorCache = [NSColor clearColor];
        }
        window.backgroundColor = clearColorCache;
        window.opaque = NO;
        
        // Force hide all background views
        forceHideBackgrounds(window.contentView);
        
        // DYNAMIC ADAPTATION: Keep glass layer at bottom and sized correctly
        NSView *glassView = glassViews[key];
        if (glassView && glassView.superview) {
            // Ensure glass is at bottom of view hierarchy
            NSView *bottomView = window.contentView.subviews.firstObject;
            if (bottomView != glassView && window.contentView.subviews.count > 1) {
                [glassView removeFromSuperview];
                [window.contentView addSubview:glassView positioned:NSWindowBelow relativeTo:window.contentView.subviews.firstObject];
                if (glassView.layer) {
                    glassView.layer.zPosition = -1000.0;
                }
            }
            
            // Dynamically adapt frame to content view bounds
            NSRect extendedFrame = NSInsetRect(window.contentView.bounds, -3, -3);
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
}

// Apply glass effect to window
static void applyGlassEffect(NSWindow *window) {
    if (!shouldModifyWindow(window) || !glassAvailable) return;
    
    NSView *contentView = window.contentView;
    if (!contentView) return;
    
    // Get or create glass view
    NSNumber *key = @((NSUInteger)window);
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
    NSNumber *key = @((NSUInteger)window);
    NSTimer *timer = windowTimers[key];
    if (timer && timer.valid) {
        [timer invalidate];
        [windowTimers removeObjectForKey:key];
    }
    
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
        NSNumber *key = @((NSUInteger)window);
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
            forceHideBackgrounds(window.contentView);
            
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
        forceHideBackgrounds(window.contentView);
        
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
        forceHideBackgrounds(window.contentView);
        
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
        if (!clearColorCache) {
            clearColorCache = [NSColor clearColor];
        }
        
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        
        if ([clipView respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [clipView setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        if ([clipView respondsToSelector:@selector(setBackgroundColor:)]) {
            @try { [clipView setBackgroundColor:clearColorCache]; } @catch (NSException *e) {}
        }
        if (clipView.layer) {
            clipView.layer.backgroundColor = [clearColorCache CGColor];
            clipView.layer.opaque = NO;
        }
        
        [CATransaction commit];
    }
    
    ZKOrig(void, newOrigin);
}

- (void)scrollToPoint:(NSPoint)newOrigin {
    // CRITICAL: During scroll, force transparency
    NSClipView *clipView = (NSClipView *)self;
    if (tweakEnabled && clipView.window && shouldModifyWindow(clipView.window)) {
        if (!clearColorCache) {
            clearColorCache = [NSColor clearColor];
        }
        
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        
        if ([clipView respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [clipView setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        if ([clipView respondsToSelector:@selector(setBackgroundColor:)]) {
            @try { [clipView setBackgroundColor:clearColorCache]; } @catch (NSException *e) {}
        }
        if (clipView.layer) {
            clipView.layer.backgroundColor = [clearColorCache CGColor];
            clipView.layer.opaque = NO;
        }
        
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
        if (!clearColorCache) {
            clearColorCache = [NSColor clearColor];
        }
        
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        
        // Force scroll view transparency
        if ([scrollView respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [scrollView setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        if ([scrollView respondsToSelector:@selector(setBackgroundColor:)]) {
            @try { [scrollView setBackgroundColor:clearColorCache]; } @catch (NSException *e) {}
        }
        if (scrollView.layer) {
            scrollView.layer.backgroundColor = [clearColorCache CGColor];
            scrollView.layer.opaque = NO;
        }
        
        // Force clip view transparency
        if ([clipView respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [clipView setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        if ([clipView respondsToSelector:@selector(setBackgroundColor:)]) {
            @try { [clipView setBackgroundColor:clearColorCache]; } @catch (NSException *e) {}
        }
        if (clipView.layer) {
            clipView.layer.backgroundColor = [clearColorCache CGColor];
            clipView.layer.opaque = NO;
        }
        
        [CATransaction commit];
    }
    
    ZKOrig(void, clipView);
}

- (void)tile {
    // Intercept tile (layout) to force transparency
    NSScrollView *scrollView = (NSScrollView *)self;
    if (tweakEnabled && scrollView.window && shouldModifyWindow(scrollView.window)) {
        if (!clearColorCache) {
            clearColorCache = [NSColor clearColor];
        }
        
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setAnimationDuration:0];
        
        if ([scrollView respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [scrollView setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        if ([scrollView respondsToSelector:@selector(setBackgroundColor:)]) {
            @try { [scrollView setBackgroundColor:clearColorCache]; } @catch (NSException *e) {}
        }
        if (scrollView.layer) {
            scrollView.layer.backgroundColor = [clearColorCache CGColor];
            scrollView.layer.opaque = NO;
        }
        
        [CATransaction commit];
    }
    
    ZKOrig(void);
}

- (void)layout {
    ZKOrig(void);
    
    // DYNAMIC ADAPTATION: Update glass layer when content view layout changes
    NSView *view = (NSView *)self;
    // Early exit if not enabled or not our window
    if (!tweakEnabled || !view.window || !shouldModifyWindow(view.window)) return;
    
    // Only process if this is the content view
    if (view != view.window.contentView) return;
    
    NSNumber *key = @((NSUInteger)view.window);
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

#pragma mark - NSView Swizzles

ZKSwizzleInterface(_AeroFinder_NSView, NSView, NSObject)
@implementation _AeroFinder_NSView

- (void)viewDidMoveToSuperview {
    NSView *view = (NSView *)self;
    
    // Early exit if not enabled
    if (!tweakEnabled || !view.window || !shouldModifyWindow(view.window)) {
        ZKOrig(void);
        return;
    }
    
    // Cache class checks
    Class viewClass = [view class];
    BOOL isVisualEffect = [view isKindOfClass:[NSVisualEffectView class]];
    
    if (isVisualEffect) {
        @synchronized(blockedViews) {
            [blockedViews addObject:[NSValue valueWithNonretainedObject:view]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [view removeFromSuperview];
        });
        return; // Don't call original
    }
    
    NSString *className = NSStringFromClass(viewClass);
    
    // INTERCEPT: Remove background views IMMEDIATELY when added to hierarchy
    if ([className isEqualToString:@"NSTitlebarBackgroundView"] ||
        [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
        [className isEqualToString:@"BackdropView"]) {
        
        @synchronized(blockedViews) {
            [blockedViews addObject:[NSValue valueWithNonretainedObject:view]];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [view removeFromSuperview];
        });
        
        return; // Don't call original
    }
    
    // Use cached clear color
    if (!clearColorCache) {
        clearColorCache = [NSColor clearColor];
    }
    
    // Force transparency for scroll views
    BOOL isScrollView = [view isKindOfClass:[NSScrollView class]];
    BOOL isClipView = !isScrollView && [view isKindOfClass:[NSClipView class]];
    
    if (isScrollView || isClipView) {
        if ([view respondsToSelector:@selector(setDrawsBackground:)]) {
            @try { [(id)view setDrawsBackground:NO]; } @catch (NSException *e) {}
        }
        if ([view respondsToSelector:@selector(setBackgroundColor:)]) {
            @try { [(id)view setBackgroundColor:clearColorCache]; } @catch (NSException *e) {}
        }
    }
    
    ZKOrig(void);
}

- (void)drawRect:(NSRect)dirtyRect {
    NSView *view = (NSView *)self;
    NSString *className = NSStringFromClass([view class]);
    
    // Check if this view is blocked
    @synchronized(blockedViews) {
        NSValue *viewValue = [NSValue valueWithNonretainedObject:view];
        if ([blockedViews containsObject:viewValue]) {
            return; // Completely skip drawing for blocked views
        }
    }
    
    // AGGRESSIVE: Skip ALL drawing for problematic views - no conditions
    if ([className isEqualToString:@"TScrollView"] ||
        [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
        [className isEqualToString:@"BackdropView"] ||
        [className isEqualToString:@"NSTitlebarBackgroundView"] ||
        [view isKindOfClass:[NSScrollView class]] ||
        [view isKindOfClass:[NSClipView class]]) {
        
        // Block this view permanently
        @synchronized(blockedViews) {
            [blockedViews addObject:[NSValue valueWithNonretainedObject:view]];
        }
        
        // COMPLETE SKIP - don't even call original
        return;
    }
    
    if (!tweakEnabled || !view.window || !shouldModifyWindow(view.window)) {
        ZKOrig(void, dirtyRect);
        return;
    }
    
    // For other views, call original
    ZKOrig(void, dirtyRect);
}

- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)ctx {
    NSView *view = (NSView *)self;
    NSString *className = NSStringFromClass([view class]);
    
    // Prevent ALL layer drawing for background views
    if ([className isEqualToString:@"TScrollView"] ||
        [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
        [className isEqualToString:@"BackdropView"] ||
        [className isEqualToString:@"NSTitlebarBackgroundView"] ||
        [view isKindOfClass:[NSScrollView class]] ||
        [view isKindOfClass:[NSClipView class]]) {
        // Don't draw anything in the layer context
        CGContextClearRect(ctx, CGContextGetClipBoundingBox(ctx));
        return;
    }
    
    ZKOrig(void, layer, ctx);
}

- (void)updateLayer {
    NSView *view = (NSView *)self;
    NSString *className = NSStringFromClass([view class]);
    
    // Skip layer updates for background views
    if ([className isEqualToString:@"TScrollView"] ||
        [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
        [className isEqualToString:@"BackdropView"] ||
        [className isEqualToString:@"NSTitlebarBackgroundView"] ||
        [view isKindOfClass:[NSScrollView class]] ||
        [view isKindOfClass:[NSClipView class]]) {
        // Force layer to be transparent
        if (view.layer) {
            if (!clearColorCache) {
                clearColorCache = [NSColor clearColor];
            }
            view.layer.backgroundColor = [clearColorCache CGColor];
            view.layer.opaque = NO;
        }
        return;
    }
    
    ZKOrig(void);
}

- (void)setFrame:(NSRect)frame {
    NSView *view = (NSView *)self;
    
    // CRITICAL: During frame changes, force transparency to prevent flicker
    if (tweakEnabled && view.window && shouldModifyWindow(view.window)) {
        if ([view isKindOfClass:[NSScrollView class]] || [view isKindOfClass:[NSClipView class]]) {
            if (!clearColorCache) {
                clearColorCache = [NSColor clearColor];
            }
            
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
        }
    }
    
    ZKOrig(void, frame);
}

- (BOOL)isOpaque {
    NSView *view = (NSView *)self;
    NSString *className = NSStringFromClass([view class]);
    
    // Force non-opaque for all scroll-related views
    if ([className isEqualToString:@"TScrollView"] ||
        [className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
        [className isEqualToString:@"BackdropView"] ||
        [className isEqualToString:@"NSTitlebarBackgroundView"] ||
        [view isKindOfClass:[NSScrollView class]] ||
        [view isKindOfClass:[NSClipView class]]) {
        return NO;
    }
    
    return ZKOrig(BOOL);
}

- (void)setNeedsDisplay:(BOOL)flag {
    NSView *view = (NSView *)self;
    NSString *className = NSStringFromClass([view class]);
    
    // Prevent display updates for background views
    if ([className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
        [className isEqualToString:@"BackdropView"] ||
        [className isEqualToString:@"NSTitlebarBackgroundView"]) {
        return;
    }
    
    ZKOrig(void, flag);
}

- (void)setNeedsDisplayInRect:(NSRect)rect {
    NSView *view = (NSView *)self;
    NSString *className = NSStringFromClass([view class]);
    
    // Prevent display updates for background views
    if ([className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
        [className isEqualToString:@"BackdropView"] ||
        [className isEqualToString:@"NSTitlebarBackgroundView"]) {
        return;
    }
    
    ZKOrig(void, rect);
}

- (void)displayIfNeeded {
    NSView *view = (NSView *)self;
    NSString *className = NSStringFromClass([view class]);
    
    // Prevent display for background views
    if ([className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
        [className isEqualToString:@"BackdropView"] ||
        [className isEqualToString:@"NSTitlebarBackgroundView"]) {
        return;
    }
    
    ZKOrig(void);
}

- (void)display {
    NSView *view = (NSView *)self;
    NSString *className = NSStringFromClass([view class]);
    
    // Prevent display for background views
    if ([className isEqualToString:@"_NSScrollViewContentBackgroundView"] ||
        [className isEqualToString:@"BackdropView"] ||
        [className isEqualToString:@"NSTitlebarBackgroundView"]) {
        return;
    }
    
    ZKOrig(void);
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
        blockedViews = [NSMutableSet set];
        displayLinks = [NSMutableDictionary dictionary];
        
        NSLog(@"[AeroFinder] Initializing glass effect tweak");
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), 
                      dispatch_get_main_queue(), ^{
            updateAllWindows();
        });
    }
}