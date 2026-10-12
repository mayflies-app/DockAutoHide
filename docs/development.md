# Development

## Requirements

Use Xcode 27 or later, macOS SDK 27 or later, Swift 6.4 or later and Python 3. The app supports macOS 13.5 or later. Run commands from the repository root.

## Command-Line Workflow

```sh
./scripts/app.py build
./scripts/app.py run
./scripts/app.py test
./scripts/app.py package
./scripts/app.py release --dry-run
```

Build and Run default to Debug, the native architecture and automatic signing. The development bundle is `dist/dev/DockAutoHide.app`. Codex Run invokes `./scripts/app.py run` and uses this same workflow.

Run builds the replacement first, normally quits the app at the development output path and launches the replacement. A different running app with the same bundle identity blocks Run; quit it before switching installations. A failed build preserves the running app. Pass application arguments after `--`.

`macos-app.json` declares identity and build settings; `VERSION` supplies the marketing version. Common CLI code lives in `scripts/app.py` and `scripts/lib/`. Package defaults to a Release Universal build with ad-hoc signing under `dist/release/universal/`. See [Releasing](releasing.md) for Developer ID packaging. `--dry-run` prints the selected plan without executing it.

## Xcode Workflow

Open `DockAutoHide.xcodeproj` and select the `DockAutoHide` scheme. Use Run to debug and Product → Archive for Xcode signing and distribution tools. Xcode and the CLI use the same product source, bundle identity, entitlements and resources.

## Product Checks

`./scripts/app.py test` runs the regression harnesses in `tools/`. They cover login-service states, menu actions, localization, display selection, Dock geometry caches, coordinate handling, invalid window records and policy start/stop behavior. Services and window/display snapshots are injected; these checks do not alter real Dock preferences or login items.

For real bilingual menu acceptance against a prebuilt app, use the common native entrypoint:

```sh
./scripts/app.py test --native --case localization \
  --app /Applications/DockAutoHide.app --output /private/tmp/dock-localization-check
```

This check needs an unlocked, idle desktop and existing permissions. It records the visible menus and restores the original language and running state on completion or interruption. See [Localization](localization.md) for prerequisites, evidence and cleanup behavior.

Run an affected isolated harness directly when narrowing a failure:

```sh
bash tools/test_launch_at_login.sh
bash tools/test_login_menu.sh
bash tools/test_multi_display_overlap.sh
bash tools/test_localization.sh
```

Set `VERBOSE=1` for decision logs. Keep results in `TestResults/` or a temporary directory. Check actual Automation authorization, login registration and physical multi-display overlap with the real app when changes affect those system boundaries.
