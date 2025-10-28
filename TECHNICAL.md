# macOS Blur Tweak - Technical Documentation

## Architecture Overview

### Core Components

1. **blurtweak.m** - Main dylib implementation
   - Window interception via ZKSwizzle
   - NSVisualEffectView management
   - Blur effect application and lifecycle

2. **blurctl.m** - CLI control tool
   - Darwin notification sender
   - User-facing configuration interface
   - Settings management

3. **Makefile** - Build system
   - Universal binary compilation
   - Dependency management
   - Installation/testing automation

## Technical Implementation

### NSVisualEffectView Integration

#### Material Selection
```objectivec
blurView.material = NSVisualEffectViewMaterialWindowBackground;
```

**Why `.windowBackground`?**
- Supports Desktop Tinting (macOS 10.14+)
- Automatically adapts to Light/Dark Mode
- Picks up wallpaper colors in Dark Mode
- Provides appropriate opacity for main windows

**Alternative Materials:**
- `.titlebar` - For titlebar-only effects
- `.sidebar` - For sidebar-specific blur
- `.hudWindow` - Darker, more opaque HUD style
- `.underWindowBackground` - For layered effects

#### Blending Mode
```objectivec
blurView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
```

**`.behindWindow` vs `.withinWindow`:**

| Mode | Blurs | Use Case |
|------|-------|----------|
| `.behindWindow` | Desktop + other windows | Transparent overlays, HUDs |
| `.withinWindow` | Content within same window | Frosted dividers, sheets |

For desktop integration, `.behindWindow` is essential.

#### State Management
```objectivec
blurView.state = NSVisualEffectStateFollowsWindowActiveState;
```

Automatically adjusts blur intensity based on window focus:
- **Active window**: Full vibrant effect
- **Inactive window**: Subdued, dimmed effect

### Window Lifecycle Management

#### 1. Window Creation
```objectivec
- (id)initWithContentRect:(NSRect)contentRect 
                styleMask:(NSWindowStyleMask)style 
                  backing:(NSBackingStoreType)backingStoreType 
                    defer:(BOOL)flag
```

**Hook point**: Inject blur view during window initialization
**Timing**: Async dispatch to ensure window is fully initialized
**Cache**: Store blur view in `windowBlurViews` dictionary

#### 2. Window Resizing
```objectivec
- (void)setFrame:(NSRect)frameRect display:(BOOL)flag
```

**Action**: Update blur view frame to match content view bounds
**Performance**: Only updates if blur view exists and is visible

#### 3. Window Focus Changes
```objectivec
- (void)becomeKeyWindow
- (void)resignKeyWindow
```

**Emphasis Effect**:
- `becomeKeyWindow`: Set `.emphasized = YES`
- `resignKeyWindow`: Set `.emphasized = NO`

Provides visual feedback for focused windows with enhanced saturation.

#### 4. Window Display
```objectivec
- (void)orderFront:(id)sender
- (void)orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)otherWin
```

**Ensures**: Blur effects are applied when window becomes visible
**Edge case**: Handles delayed window visibility

#### 5. Window Cleanup
```objectivec
- (void)close
```

**Important**: Remove blur view from cache before closing
**Memory**: Prevents retain cycles and memory leaks

### Transparent Titlebar Implementation

```objectivec
window.titlebarAppearsTransparent = YES;
window.styleMask |= NSWindowStyleMaskFullSizeContentView;
```

**Effects**:
1. Removes titlebar background
2. Extends content view to full window bounds
3. Content can draw under titlebar
4. Traffic lights remain visible

**Combined with blur**:
- Blur view covers entire window including titlebar area
- Creates seamless blended appearance
- Titlebar controls float above blur

### Vibrancy System

#### View-Level Vibrancy
```objectivec
- (BOOL)allowsVibrancy {
    return YES;
}
```

**Enabled for**:
- `NSTextField` - Labels, text
- `NSTextView` - Editable text
- `NSImageView` - Icons, images

**Effect**:
- Text automatically adjusts contrast
- Uses system colors for best results
- Maintains readability over blur

**Best Practices**:
```objectivec
// Use system colors
NSColor.labelColor            // Highest contrast
NSColor.secondaryLabelColor   // Medium contrast
NSColor.tertiaryLabelColor    // Lower contrast
NSColor.quaternaryLabelColor  // Lowest contrast
```

These colors adapt to vibrancy automatically.

### Window Filtering Logic

```objectivec
static inline BOOL shouldApplyBlurEffects(NSWindow *window)
```

**Exclusions**:
1. **NSPanel subclasses** - Alerts, dialogs, file pickers
2. **Utility windows** - Small floating panels
3. **HUD windows** - Heads-up displays
4. **Modal sheets** - Dialog sheets
5. **Untitled windows** - Windows without titlebar

**Reasoning**:
- System dialogs should remain standard
- Prevents blur on critical UI (alerts)
- Maintains consistency with macOS design

### Memory Management

#### View Caching Strategy
```objectivec
static NSMutableDictionary<NSNumber *, NSVisualEffectView *> *windowBlurViews;
```

**Key**: Window pointer cast to NSNumber
**Value**: Associated NSVisualEffectView instance

**Benefits**:
- Avoids creating multiple blur views per window
- Fast lookup for existing views
- Centralized cleanup

**Lifecycle**:
1. Created on first window access
2. Reused on subsequent calls
3. Removed on window close

#### ARC Considerations
All code uses ARC (Automatic Reference Counting):
```makefile
-fobjc-arc
```

**No manual retain/release needed**
**Careful with**:
- Block capture semantics
- Delegate patterns (use weak references)
- NSNotificationCenter removal

### Performance Optimizations

#### 1. Inline Functions
```objectivec
static inline BOOL shouldApplyBlurEffects(NSWindow *window)
```
Hot-path function inlined for zero call overhead.

#### 2. Lazy Initialization
Blur views only created when needed, not proactively.

#### 3. Minimal Swizzling
Only essential methods swizzled:
- Window lifecycle (init, close)
- Frame updates (setFrame)
- Focus changes (becomeKey, resignKey)

#### 4. GPU Acceleration
NSVisualEffectView is GPU-accelerated by Apple:
- No CPU-based blur calculations
- Native Core Image pipeline
- Efficient compositing

#### 5. State Caching
```objectivec
BOOL needsUpdate = (enableBlurTweak != enable || ...);
```
Only updates windows when settings actually change.

### Darwin Notifications (IPC)

#### Notification Names
```
com.blur.tweak.enable              # Enable blur
com.blur.tweak.disable             # Disable blur
com.blur.tweak.toggle              # Toggle state
com.blur.tweak.titlebar.enable     # Enable transparent titlebar
com.blur.tweak.titlebar.disable    # Disable transparent titlebar
com.blur.tweak.vibrancy.enable     # Enable vibrancy
com.blur.tweak.vibrancy.disable    # Disable vibrancy
com.blur.tweak.emphasize.enable    # Enable emphasis
com.blur.tweak.emphasize.disable   # Disable emphasis
com.blur.tweak.intensity           # Set blur intensity
```

#### Current Implementation
CLI sends notifications, dylib does not yet listen.

#### Future Enhancement
Add notification listeners in dylib:
```objectivec
static void setupNotifications(void) {
    int token;
    notify_register_dispatch("com.blur.tweak.enable",
                            &token,
                            dispatch_get_main_queue(),
                            ^(int t) {
        configureBlurTweak(YES, enableTransparentTitlebar, 
                          enableVibrancy, emphasizeFocusedWindows);
    });
}
```

### Build System Details

#### Universal Binary Compilation
```makefile
ARCHS = -arch x86_64 -arch arm64 -arch arm64e
```

**Supports**:
- Intel Macs (x86_64)
- Apple Silicon M1/M2/M3 (arm64)
- Apple Silicon with preview ABI (arm64e)

#### Framework Linking
```makefile
-framework Foundation
-framework AppKit
-framework QuartzCore
-framework Cocoa
-framework CoreFoundation
```

**AppKit**: Window management, NSVisualEffectView
**QuartzCore**: Core graphics, compositing
**Foundation**: Base Objective-C runtime

#### Separate CLI Linking
```makefile
# CLI tool - NO AppKit to avoid injection
-framework Foundation
-framework CoreFoundation
```

**Critical**: CLI must not link AppKit
**Reason**: Prevents DYLD_INSERT_LIBRARIES from affecting CLI itself

## Testing Strategy

### Test Applications
```makefile
TEST_APPS := Finder Safari Notes "System Settings" Calculator TextEdit
```

**Coverage**:
- **Finder**: Core system app, complex UI
- **Safari**: Modern web browser, many windows
- **Notes**: Document-based app
- **System Settings**: Complex panels
- **Calculator**: Simple single-window app
- **TextEdit**: Document app with multiple windows

### Test Procedure
```bash
make test
```

1. Build latest version
2. Install to system
3. Force-quit all test apps
4. Relaunch test apps
5. Verify blur effects applied

### Visual Verification
- Windows should show desktop blur
- Titlebars should be transparent
- Focused windows should appear more saturated
- Text should remain readable

## Known Limitations

### 1. Real-time Settings Updates
Currently requires app restart to apply settings changes.

**Future**: Implement Darwin notification listeners in dylib.

### 2. Per-App Configuration
All apps get same blur settings.

**Future**: App-specific configuration files.

### 3. Blur Intensity Control
Hardcoded to material defaults.

**Future**: Custom blur radius/opacity controls.

### 4. Compatibility
Tested on macOS 13+ (Ventura, Sonoma, Sequoia).

**Older versions**: May work but untested.

## Debugging

### Enable Logging
Check Console.app for `[BlurTweak]` messages:
```bash
log stream --predicate 'eventMessage contains "BlurTweak"'
```

### Common Issues

**No blur visible**:
- Check window is not in blacklist
- Verify window type (should be titled, not panel)
- Check blur view was created (NSLog)

**Poor performance**:
- Reduce number of windows
- Check for other system load
- Verify GPU acceleration enabled

**Text unreadable**:
- Enable vibrancy
- Use system colors in apps
- Reduce blur intensity (future feature)

## Security Considerations

### Required Compromises
- SIP must be disabled
- Library validation must be disabled
- System less secure overall

### Attack Surface
- Dylib injection means code runs in all apps
- Potential for malicious tweaks
- Reduced sandboxing effectiveness

### Mitigation
- Source code transparency
- Code signing (future)
- Minimal permissions requested

## Future Enhancements

### High Priority
1. Darwin notification handlers in dylib
2. Per-app blur configuration
3. Adjustable blur intensity
4. Material selection options

### Medium Priority
1. Window-specific settings
2. Animation customization
3. Performance profiling
4. macOS version detection

### Low Priority
1. GUI configuration app
2. Preset blur themes
3. Time-based blur changes
4. Integration with other tweaks

## Contributing Guidelines

### Code Style
- Use ARC exclusively
- Inline hot-path functions
- Comment complex logic
- Follow Apple naming conventions

### Testing Requirements
- Test on Intel and Apple Silicon
- Verify all test apps work
- Check memory leaks with Instruments
- Profile performance impact

### Pull Request Process
1. Fork repository
2. Create feature branch
3. Test thoroughly
4. Document changes
5. Submit PR with description

---

**Last Updated**: 2025-10-27
**macOS Compatibility**: 13.0+ (Ventura, Sonoma, Sequoia)
**Architecture**: Universal (x86_64, arm64, arm64e)
