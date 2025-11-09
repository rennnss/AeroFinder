# macOS Finder Advanced Material Tweak with Liquid Glass

An advanced macOS tweak that applies sophisticated material rendering to Finder windows using Apple's latest **Liquid Glass** technology (NSGlassEffectView) with graceful fallback to NSVisualEffectView for older systems.

## Features

- **🎨 Liquid Glass Effects**: Uses macOS 15+ NSGlassEffectView for the latest dynamic glass material
- **🔄 Automatic Fallback**: Seamlessly falls back to NSVisualEffectView on older macOS versions
- **⚡ Performance Optimized**: Uses NSGlassEffectContainerView for efficient morphing and rendering
- **🪟 Dual-Layer Material System**: Window-level and navigation-level blur effects
- **🌈 Desktop Transparency**: Window backgrounds blend with desktop wallpaper
- **📁 Navigation Area Effects**: File browser areas have distinct within-window blur
- **🌓 Dynamic Theme Adaptation**: Automatically updates materials for light/dark mode
- **🎯 Finder-specific**: Only affects Finder windows, not system dialogs
- **🎚️ Adjustable Intensity**: Control blur strength in real-time (0-100%)
- **🧩 Modular Design**: Toggle window and navigation effects independently
- **⌨️ CLI Control**: Full command-line interface for runtime configuration

## What is Liquid Glass?

Liquid Glass is Apple's new dynamic material introduced in macOS 15.0 (SDK 26.0) that combines the optical properties of glass with a sense of fluidity. It provides:

- **Morphing animations** between interface states
- **Adaptive opacity** based on context and focus
- **Hardware-informed curvature** matching device design
- **System-wide consistency** with native macOS applications
- **Automatic appearance adaptation** for light/dark modes

This tweak brings Liquid Glass to Finder windows, creating a modern, translucent interface that blends beautifully with your desktop.

## Architecture

### Liquid Glass vs NSVisualEffectView

**macOS 15.0+ (Liquid Glass)**
- Uses `NSGlassEffectView` for modern glass effects
- Wrapped in `NSGlassEffectContainerView` for performance
- Automatic morphing animations between states
- Enhanced vibrancy and depth perception
- System-managed appearance updates

**macOS 14.0 and earlier (Fallback)**
- Uses `NSVisualEffectView` for blur effects
- Manual material selection based on appearance
- Compatible blending modes maintained
- Feature parity with reduced visual fidelity

### Material Layers

**Window Background**
- **Liquid Glass**: `NSGlassEffectView` (automatic style)
- **Fallback**: `NSVisualEffectMaterialUnderWindowBackground`
- Blending: Blends with desktop and windows behind
- Use case: Desktop wallpaper visible through Finder

**Navigation Areas**
- **Liquid Glass**: `NSGlassEffectView` (automatic style)
- **Fallback**: `NSVisualEffectMaterialContentBackground`
- Blending: Blends with window content only (WithinWindow mode for fallback)
- Use case: File lists, browsers, icon views

### Supported Navigation Views
- NSBrowser (Column view)
- NSOutlineView (List view)
- NSTableView (Table views)
- NSCollectionView (Icon/Gallery views)
- Finder-specific private classes

## Installation

```bash
git clone https://github.com/rennnss/AeroFinder.git
cd AeroFinder
make clean && make && sudo make install
```

### Requirements
- **macOS 14.0+** (macOS 15.0+ recommended for Liquid Glass)
- SIP disabled for dylib injection
- Library validation disabled

**For best results**: Use macOS 15.0 (Sequoia) or later to experience full Liquid Glass effects. On macOS 14.x (Sonoma) and earlier, the tweak automatically uses NSVisualEffectView with similar visual results.

```bash
# Disable SIP (restart to Recovery Mode, then in Terminal):
csrutil disable

# Disable library validation
sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true
```

## Usage

Control the tweak using the CLI tool:

```bash
blurctl on                  # Enable all blur effects
blurctl off                 # Disable all blur effects
blurctl toggle              # Toggle master switch
blurctl nav-toggle          # Toggle navigation area blur only
blurctl --intensity 75      # Set blur intensity (0-100)
blurctl status              # Show current settings
```

### Examples

```bash
# Enable with 50% intensity
blurctl --intensity 50
blurctl on

# Disable navigation blur but keep window blur
blurctl nav-toggle

# Full transparency effect
blurctl --intensity 100

# Subtle effect
blurctl --intensity 30
```

## Configuration

### Persistent Settings
Settings are stored in `~/Library/Preferences/com.blur.tweak.plist`

```xml
<dict>
    <key>enabled</key>
    <true/>
    <key>navigationBlur</key>
    <true/>
    <key>intensity</key>
    <integer>85</integer>
</dict>
```

### Runtime Control
The tweak responds to Darwin notifications:
- `com.blur.tweak.enable` - Enable all effects
- `com.blur.tweak.disable` - Disable all effects
- `com.blur.tweak.toggle` - Toggle master switch
- `com.blur.tweak.navigation.toggle` - Toggle navigation blur
- `com.blur.tweak.intensity` - Set intensity (0-100)

## Technical Details

### Liquid Glass Implementation

The tweak automatically detects Liquid Glass availability at runtime:

```objc
// Check for NSGlassEffectView (macOS 15.0+)
Class glassClass = NSClassFromString(@"NSGlassEffectView");
if (glassClass != nil) {
    // Use Liquid Glass
    blurView = [[glassClass alloc] initWithFrame:...];
    
    // Wrap in container for performance
    Class containerClass = NSClassFromString(@"NSGlassEffectContainerView");
    container = [[containerClass alloc] initWithFrame:...];
} else {
    // Fallback to NSVisualEffectView
    blurView = [[NSVisualEffectView alloc] initWithFrame:...];
    blurView.material = NSVisualEffectMaterialUnderWindowBackground;
    blurView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
}
```

### Material Rendering Pipeline
1. Window creation intercepted via method swizzling
2. Liquid Glass availability checked
3. **If Liquid Glass available**:
   - Create `NSGlassEffectView` for window background
   - Wrap in `NSGlassEffectContainerView` for performance optimization
   - Create `NSGlassEffectView` instances for each navigation view
   - Container automatically merges nearby glass effects for smooth morphing
4. **If Liquid Glass unavailable** (fallback):
   - Create `NSVisualEffectView` with BehindWindow blending
   - Navigation views get WithinWindow `NSVisualEffectView` instances
   - Materials updated manually on theme changes
5. Views cached and reused across lifecycle

### Dynamic Updates
- **Navigation Changes**: New views automatically detected and blurred
- **Window Resize**: Blur views resize with autoresizing masks
- **Theme Transitions**: Materials update via appearance change notifications
- **Performance**: Blur views cached and reused across lifecycle

### Safety Features
- Only public AppKit APIs used (sandbox-safe)
- Non-breaking to Finder core functions
- Excludes system UI (panels, menus, HUD windows)
- Graceful fallback for unknown view types
- No retain cycles or memory leaks

## Implementation

See [IMPLEMENTATION.md](IMPLEMENTATION.md) for detailed technical documentation including:
- Architecture diagrams
- API usage patterns
- Method swizzling details
- Extension points
- Performance considerations
- Troubleshooting guide

## Building

```bash
# Clean build
make clean

# Build dylib and CLI tool
make

# Install to system
sudo make install

# Build and test immediately
make test

# Uninstall
sudo make uninstall
```

## Testing

After installation:

```bash
# Restart Finder
killall Finder

# Enable the effect
blurctl on

# Open a Finder window and navigate through folders
open ~/Documents

# Test intensity changes
for i in {0..100..10}; do
    blurctl --intensity $i
    sleep 0.5
done

# Toggle navigation blur while navigating
blurctl nav-toggle
```

## Troubleshooting

### Blur not appearing
1. Verify SIP is disabled: `csrutil status`
2. Check library validation: `defaults read /Library/Preferences/com.apple.security.libraryvalidation.plist`
3. Restart Finder: `killall Finder`
4. Check if enabled: `blurctl status`

### Performance issues
1. Lower intensity: `blurctl --intensity 40`
2. Disable navigation blur: `blurctl nav-toggle`
3. Check Activity Monitor for Finder CPU usage

### Theme not updating
1. Toggle the effect: `blurctl toggle && blurctl toggle`
2. Restart Finder: `killall Finder`
3. Check Console.app for `[BlurTweak]` logs

## Notes

- The tweak does not apply to other apps or system dialogs
- Requires dylib injection (via DYLD_INSERT_LIBRARIES or similar)
- Finder must be restarted after enabling/disabling
- Performance impact is minimal (compositing done by GPU)
- Compatible with Finder's native transparency features

## Advanced Usage

### Custom Material Selection
Edit `blurtweak.m` and modify `getMaterialForAppearance()`:

```objc
static NSVisualEffectMaterial getMaterialForAppearance(BOOL isNavigationArea) {
    if (isNavigationArea) {
        return NSVisualEffectMaterialSidebar;  // Use sidebar material
    }
    return NSVisualEffectMaterialUnderWindowBackground;
}
```

### Add Custom Navigation View Types
Edit `isNavigationView()`:

```objc
if ([className containsString:@"YourCustomView"]) {
    return YES;
}
```

## References

- [NSVisualEffectView Documentation](https://developer.apple.com/documentation/appkit/nsvisualeffectview)
- [Material Types](https://developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum)
- [Blending Modes](https://developer.apple.com/documentation/appkit/nsvisualeffectview/blendingmode-swift.enum)
- [Appearance Customization](https://developer.apple.com/documentation/appkit/appearance-customization)

## License

MIT License

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Test thoroughly on multiple macOS versions
4. Submit a pull request

## Acknowledgments

- ZKSwizzle for method swizzling framework
- Apple's AppKit team for NSVisualEffectView APIs
- macOS transparency and blur effect inspiration
