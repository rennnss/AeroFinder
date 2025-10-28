# macOS Blur Tweak

An advanced window blending tweak for macOS that uses `NSVisualEffectView` to create seamless desktop integration with translucent, blurred windows that adapt to your wallpaper.

![License](https://img.shields.io/badge/license-MIT-blue.svg)

## Features

- **Desktop Blending**: Windows blend with desktop wallpaper using `.behindWindow` mode
- **Transparent Titlebars**: Seamless titlebar integration with blur effects
- **Desktop Tinting**: Automatically adapts window colors to desktop wallpaper (Dark/Light Mode)
- **Vibrancy Effects**: Foreground content (text, icons) maintains readability with automatic contrast
- **Focused Window Emphasis**: Active windows get enhanced saturation and depth
- **Universal Binary**: Supports Intel (x86_64) and Apple Silicon (arm64, arm64e)

## Visual Effects

The tweak applies the following effects:

1. **NSVisualEffectView** with `.windowBackground` material
2. **Blending Mode**: `.behindWindow` for natural desktop integration
3. **Dynamic Tinting**: Picks up colors from desktop wallpaper in Dark Mode
4. **Emphasis**: Focused windows get `.emphasized = true` for enhanced depth
5. **Vibrancy**: Text and icons automatically adjust contrast against blurred backgrounds

## Requirements

- macOS Ventura or later (tested on Sonoma and Sequoia)
- [Ammonia](https://github.com/CoreBedtime/ammonia) injection system installed
- System Integrity Protection (SIP) disabled
- Library Validation disabled

### System Security Settings

To disable required security features:

1. Boot into Recovery Mode
2. Open Terminal and run:
   ```bash
   csrutil disable
   ```
3. Restart and run:
   ```bash
   sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true
   ```
4. For Apple Silicon:
   ```bash
   sudo nvram boot-args="-arm64e_preview_abi"
   ```

## Installation

### From Source

1. Ensure Ammonia is installed:
   ```bash
   git clone https://github.com/CoreBedtime/ammonia
   cd ammonia
   ./install.sh
   ```

2. Build and install the blur tweak:
   ```bash
   cd macos-blur-tweak
   make
   sudo make install
   ```

3. Test the tweak:
   ```bash
   make test
   ```

## Usage

### CLI Commands

Control the blur tweak using the `blurctl` command:

```bash
# Enable/disable blur effects
blurctl on
blurctl off
blurctl toggle

# Configure specific features
blurctl --titlebar off       # Disable transparent titlebars
blurctl --vibrancy on        # Enable vibrancy for text/icons
blurctl --emphasize on       # Emphasize focused windows
blurctl --intensity 75       # Set blur intensity (0-100)

# Check status
blurctl status
```

### Configuration Options

- **Transparent Titlebar**: Makes titlebars blend seamlessly with content
- **Vibrancy**: Enhances foreground content contrast (recommended ON)
- **Emphasis**: Makes focused windows more saturated (recommended ON)
- **Intensity**: Controls blur strength (0 = no blur, 100 = maximum)

## How It Works

The tweak uses method swizzling to inject `NSVisualEffectView` into window hierarchies:

1. **Window Creation**: Intercepts `initWithContentRect:` to add blur views
2. **Blur View Injection**: Inserts `NSVisualEffectView` as background layer
3. **Material Selection**: Uses `.windowBackground` for desktop tinting support
4. **Blending Mode**: Sets `.behindWindow` to blend with desktop/other windows
5. **Dynamic Updates**: Tracks window focus to apply emphasis effects

### Key Implementation Details

```objectivec
// Create blur view with desktop blending
NSVisualEffectView *blurView = [[NSVisualEffectView alloc] init];
blurView.material = NSVisualEffectViewMaterialWindowBackground;  // Desktop tinting
blurView.blendingMode = NSVisualEffectBlendingModeBehindWindow;  // Blend with desktop
blurView.state = NSVisualEffectStateFollowsWindowActiveState;    // Auto-adapt

// Enable vibrancy for text readability
- (BOOL)allowsVibrancy {
    return YES;  // For NSTextField, NSTextView, NSImageView
}
```

## Excluded Windows

The tweak intelligently excludes:

- **Alert Dialogs**: `NSPanel` subclasses (alerts, save dialogs)
- **Utility Windows**: HUD windows, tooltips, popovers
- **Modal Sheets**: Sheet-style dialogs
- **System Processes**: See `libblur_tweak.dylib.blacklist`

This ensures system dialogs and critical UI remain standard while main application windows get blur effects.

## Performance

The tweak is optimized for performance:

- **Cached Blur Views**: Views are created once and reused
- **Smart Updates**: Only updates on window state changes
- **Efficient Rendering**: Uses native `NSVisualEffectView` (GPU-accelerated)
- **Minimal Overhead**: Swizzling only essential window methods

## Comparison with Apple Sharpener

| Feature | Apple Sharpener | macOS Blur Tweak |
|---------|----------------|------------------|
| **Goal** | Square window corners | Desktop-blended translucency |
| **Method** | Corner radius override | NSVisualEffectView injection |
| **Visual Effect** | Sharp geometric edges | Soft blur and translucency |
| **Desktop Integration** | None | Full wallpaper tinting |
| **Performance Impact** | Minimal | Low (GPU-accelerated) |

Both tweaks can coexist - use together for square + blurred windows!

## Troubleshooting

### Windows Not Blurring

1. Check if tweak is enabled: `blurctl status`
2. Ensure app is not blacklisted
3. Restart the app: `make test`
4. Check Console.app for `[BlurTweak]` logs

### Poor Performance

1. Reduce blur intensity: `blurctl --intensity 50`
2. Disable vibrancy: `blurctl --vibrancy off`
3. Add problematic apps to blacklist

### Text Readability Issues

1. Enable vibrancy: `blurctl --vibrancy on`
2. Use system colors (`labelColor`, `secondaryLabelColor`) in custom apps
3. Adjust blur intensity

## Development

### Building

```bash
make clean && make
```

### Testing

```bash
sudo make test
```

### Debugging

Check logs in Console.app filtered by `[BlurTweak]`:

```bash
log stream --predicate 'eventMessage contains "BlurTweak"'
```

## Architecture

```
macos-blur-tweak/
├── src/
│   ├── blurtweak.m      # Main tweak implementation
│   └── blurctl.m        # CLI control tool
├── Makefile             # Build system
├── libblur_tweak.dylib.blacklist  # Process exclusions
└── README.md
```

## Contributing

Contributions welcome! Areas for improvement:

- Per-app blur intensity settings
- Custom material selection
- Advanced vibrancy controls
- Performance optimizations
- macOS version compatibility

## License

MIT License - see LICENSE file

## Acknowledgments

- [Ammonia](https://github.com/CoreBedtime/ammonia) - Injection framework
- [ZKSwizzle](https://github.com/alexzielenski/ZKSwizzle) - Method swizzling
- Apple's NSVisualEffectView documentation

## ⚠️ Security Notice

This tweak requires disabling macOS security features. Use only on systems where you understand the security implications. Always download from trusted sources.

## Related Projects

- [Apple Sharpener](../) - Square window corners tweak (same repository)
- Together they create a unique macOS aesthetic: square corners + desktop blur

---

**Made with ❤️ for macOS power users who want more control over their desktop appearance**
