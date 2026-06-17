# Pastes

A macOS clipboard history manager. View, search, pin, and manage your clipboard records with one click.

[中文文档](README_CN.md)

## Features

- **Clipboard History** — Automatically records all copied text and images
- **Rich Text Support** — Preserves original formatting (Word, code, etc.)
- **Global Hotkey** — Default `⌘⇧V` to summon from anywhere, fully customizable
- **One-Click Paste** — Click an item to copy and paste directly at cursor position
- **Pin Favorites** — Pin important items to the top, unaffected by cleanup
- **Search** — Quickly search through clipboard history
- **History Limit** — Configurable max items, auto-removes oldest entries
- **Launch at Login** — Optional auto-start on macOS login
- **Bilingual UI** — Chinese and English supported
- **Menu Bar App** — Lives in the menu bar, no Dock icon

## Installation

### Download DMG

Download the latest `Pastes.dmg` from [Releases](../../releases), open it and drag Pastes into the Applications folder.

> On first launch, macOS may show "unidentified developer". Right-click the app → select "Open".

### Build from Source

```bash
git clone git@github.com:flow2dream/pastes.git
cd pastes
open pastes.xcodeproj
```

Run with `⌘R` in Xcode.

### Build DMG Installer

```bash
# Build Release
xcodebuild -project pastes.xcodeproj -scheme pastes -configuration Release -derivedDataPath build clean build

# Create DMG
mkdir -p dmg_staging
cp -R build/Build/Products/Release/pastes.app dmg_staging/
ln -s /Applications dmg_staging/Applications
hdiutil create -volname "Pastes" -srcfolder dmg_staging -ov -format UDZO Pastes.dmg

# Clean up
rm -rf dmg_staging build
```

The generated `Pastes.dmg` is ready for distribution.

## Permissions

- **Accessibility** — Required for auto-paste feature (simulates Cmd+V). A permission prompt will appear on first launch, or enable manually in System Settings → Privacy & Security → Accessibility.

## Usage

| Action | Description |
|--------|-------------|
| `⌘⇧V` | Show/hide clipboard panel (global hotkey) |
| Click item | Copy and paste to current focus |
| Pin button | Pin/unpin an item |
| × button | Delete an item |
| Left-click menu bar icon | Show panel |
| Right-click menu bar icon | Settings / Quit |

## System Requirements

- macOS 26.0 or later

## License

MIT License
