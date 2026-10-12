# Dock Auto Hide

Keep the Dock visible until a window needs its space. Dock Auto Hide is a native macOS menu bar app that controls Dock auto-hide from window overlap.

## Features

- Smart Switching hides the Dock when a window overlaps it and shows it when the space is clear.
- Manual control sets Dock auto-hide when Smart Switching is off.
- Menu status shows the actual Dock state and explains permission or login-item errors.
- English and Simplified Chinese interfaces update immediately.
- Optional Launch at Login uses macOS Login Items.

## Requirements

macOS 13.5 or later, on Apple Silicon or Intel. System Events Automation permission is required for Dock control. Optional Screen Recording permission improves the window metadata available to Smart Switching.

## Installation

Install the published release with Homebrew:

```sh
brew tap mayflies-app/tap
brew install --cask dockautohide
```

Homebrew installs the version published in the [tap](https://github.com/mayflies-app/homebrew-tap). To use the source in this checkout, follow [Development](docs/development.md).

## Usage

Open Dock Auto Hide and click its menu bar icon:

- Enable **Smart Switching** for automatic control.
- Use **Dock Auto-Hide** for manual control with Smart Switching off.
- Choose **Interface Language → 简体中文** or **English** to change the interface.
- Enable **Launch at Login** to start the app when signing in. A mixed checkmark indicates approval is required; **Open Login Items Settings…** opens the macOS approval page.
- Choose **Quit** to exit. The app restores the selected manual auto-hide setting when it has Automation permission.

The app has no main window or Dock icon. Status and error rows explain why a control is unavailable.

## Privacy

Dock Auto Hide processes window and display geometry locally. It does not capture screenshots or send data over the network. Allow System Events control in **System Settings → Privacy & Security → Automation**. You can grant optional Screen Recording access in **System Settings → Privacy & Security → Screen Recording**. See [Privacy](docs/privacy.md) for details.

## Development

Use `./scripts/app.py build`, `run`, `test`, `package` and `release --dry-run`, or open `DockAutoHide.xcodeproj` in Xcode. See [Development](docs/development.md), [Localization](docs/localization.md) and [Releasing](docs/releasing.md).

## Contributing

See [Contributing](CONTRIBUTING.md). Maintained by [Mayflies](https://github.com/mayflies-app); support is available through [GitHub Sponsors](https://github.com/sponsors/nshcr).

## License

[MIT](LICENSE).
