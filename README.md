# macOS Finder Transparency Tweak

<img width="1393" height="718" alt="image" src="https://github.com/user-attachments/assets/0c5b9233-b52a-4571-b826-a3f5c4602823" />

This tweak modifies the Finder window appearance on macOS:

## Features

- **Finder-specific**: Only affects Finder windows.
- **Adjustable transparency**: Makes Finder windows more transparent, removing blur effects.
- **No blur**: Blur is fully disabled; only transparency is applied.
- **CLI tool**: Use `blurctl` to enable/disable the effect and adjust intensity in real time.

## Usage

Control the tweak using the CLI tool:

```bash
blurctl on         # Enable transparency
blurctl off        # Disable transparency
blurctl toggle     # Toggle effect
blurctl --intensity 75   # Set transparency intensity (0-100)
blurctl status     # Show current status
```

## Notes

- The tweak does not apply to other apps or system dialogs.
- No blur or vibrancy is used—only transparency.
- Requires SIP and Library Validation to be disabled and ammonia for injection.

## Install

- Install ammonia from : https://github.com/CoreBedtime/ammonia
```bash
git clone https://github.com/rennnss/AeroFinder.git

cd AeroFinder

make && sudo make install
```

- Restart Finder, and use the CLI tool to toggle it on and off,
- NOTE: currently the tweak does work with off, but you will have to restart finder once you turn it off.

## License

MIT License
