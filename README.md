# QuickRes

QuickRes is a lightweight macOS menu bar app to switch display resolutions.

## Install (Free / Developer-Friendly)

- Download the latest build: [Latest QuickRes release](https://github.com/Sohan022/QuickRes/releases/latest)
- Download `QuickRes-<version>-macOS-unsigned.zip` from Assets.
- Unzip it in your preferred location (you should see `QuickRes.app`).
- Open `QuickRes.app`. It will appear in the macOS menu bar.

### If macOS blocks it (expected for free non-notarized builds)

Option 1:
- Right-click `QuickRes.app` -> `Open` -> `Open`.

Option 2:
- Run:
```bash
xattr -dr com.apple.quarantine /path/to/downloaded/app/QuickRes.app
```

## Build From Source

```bash
git clone https://github.com/Sohan022/QuickRes.git
cd QuickRes
swift run QuickRes
```

After launch, click the display icon in the macOS menu bar and choose a display resolution.

## Features

- Shows all currently active displays (built-in + external monitors).
- Curated default list with `Recommended`, `More Modes`, and `Legacy / Low Resolution` sections.
- Advanced toggle to show all available modes.
- Switches mode with one click from the menu bar.
- Confirms first-time switches for risky modes (legacy or low-quality options).

## Notes

- This project uses a free distribution model (ad-hoc signed, not Apple notarized).
- Available resolutions depend on your display hardware/adapter.
