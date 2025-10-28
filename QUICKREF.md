# macOS Blur Tweak - Quick Reference

## 🎯 One-Line Description
Advanced NSVisualEffectView-based tweak for transparent, desktop-blended windows with blur effects.

## ⚡ Quick Commands

```bash
# Build & Install
make && sudo make install

# Test
make test

# Control
blurctl on
blurctl off
blurctl --titlebar on
blurctl --vibrancy on
blurctl --emphasize on

# Uninstall
sudo make uninstall
```

## 🔑 Key Files

| File | Purpose |
|------|---------|
| `src/blurtweak.m` | Main implementation |
| `src/blurctl.m` | CLI tool |
| `Makefile` | Build system |
| `README.md` | User guide |
| `TECHNICAL.md` | Dev docs |

## 🎨 Visual Effects Stack

```
Window Hierarchy:
┌─────────────────────────────┐
│  NSWindow                   │
│  ┌───────────────────────┐  │
│  │ NSVisualEffectView    │  │ ← Blur layer (behind everything)
│  │ .material = .windowBg │  │
│  │ .blend = .behindWin   │  │
│  ├───────────────────────┤  │
│  │ App Content Views     │  │ ← Your app content
│  │ (with vibrancy)       │  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

## 🔧 Architecture

```
Method Swizzling (ZKSwizzle):
NSWindow.initWithContentRect:  → Inject blur view
NSWindow.setFrame:             → Update blur size
NSWindow.becomeKeyWindow:      → Apply emphasis
NSWindow.resignKeyWindow:      → Remove emphasis
NSView.allowsVibrancy:         → Enable text vibrancy
```

## 📊 Feature Comparison

| Feature | Apple Sharpener | Blur Tweak |
|---------|----------------|------------|
| Corner Style | Square | Rounded (native) |
| Transparency | None | Full |
| Desktop Blend | ❌ | ✅ |
| Wallpaper Tint | ❌ | ✅ (Dark Mode) |
| Vibrancy | ❌ | ✅ |
| Compatible | ✅ | ✅ |

## 🚀 Installation Locations

```
/var/ammonia/core/tweaks/libblur_tweak.dylib
/var/ammonia/core/tweaks/libblur_tweak.dylib.blacklist
/usr/local/bin/blurctl
```

## 🎛️ Configuration (Future)

```objectivec
// Current (hardcoded):
.material = NSVisualEffectMaterialWindowBackground
.blendingMode = NSVisualEffectBlendingModeBehindWindow
.state = NSVisualEffectStateFollowsWindowActiveState
.emphasized = (window.isKeyWindow && emphasizeFocusedWindows)

// Future: Runtime configurable via blurctl
```

## 🐛 Debug

```bash
# View logs
log stream --predicate 'eventMessage contains "BlurTweak"'

# Console.app filter: [BlurTweak]
```

## ⚠️ Requirements

- macOS 13+ (Ventura, Sonoma, Sequoia)
- SIP disabled
- Library Validation disabled
- Ammonia injection system
- Apple Silicon: `-arm64e_preview_abi` boot-arg

## 🎯 Use Cases

1. **Minimal Desktop** - Windows blend with wallpaper
2. **Modern Aesthetic** - iOS-style translucency
3. **Focus Indication** - Emphasized active windows
4. **Custom Theming** - Wallpaper-based color adaptation

## 🔄 Workflow

```bash
# Development cycle:
1. Edit src/blurtweak.m
2. make clean && make
3. sudo make install
4. make test
5. Check visual results
6. Repeat
```

## 📞 Troubleshooting

| Issue | Solution |
|-------|----------|
| No blur | Check blacklist, verify window type |
| Text unreadable | Enable vibrancy: `blurctl --vibrancy on` |
| Poor performance | Check GPU usage, reduce window count |
| Build error | Verify ZKSwizzle path, check Xcode |

---

**Ready to go!** Run `make && sudo make install && make test` to see it in action! 🎉
