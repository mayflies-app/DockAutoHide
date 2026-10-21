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

Shared scripts, workflows, and declared design and localization helpers are maintained in `homebrew-tap/templates/macos-app`. The `shared` object in this repository's `macos-app.json` declares helper destinations relative to this repository. Update shared implementation in the tap, then run from the tap checkout root:

```sh
python3 -B scripts/sync_apps.py --check APP_CHECKOUT
python3 -B scripts/sync_apps.py --apply APP_CHECKOUT
```

Replace `APP_CHECKOUT` with this app's checkout directory; multiple explicit checkout arguments are accepted. The check is read-only; apply copies shared files. Review local and staged changes before applying and inspect the resulting diff. Checkouts can live in any directory: do not commit host-specific paths or a workspace layout. App configuration, translations, product behavior and targeted checks stay in this repository. Follow [Shared Maintenance](https://github.com/mayflies-app/homebrew-tap/tree/main/templates/macos-app#shared-maintenance) for validation scope.

## Xcode Workflow

Open `DockAutoHide.xcodeproj` and select the `DockAutoHide` scheme for Build, Run, Debug or Archive. Xcode and the CLI use the same product source, bundle identity, entitlements and resources.

Debug and Release use ad-hoc signing by default and do not require an Apple Developer team. Hardened Runtime remains enabled. For Developer ID distribution, explicitly select your signing identity and team in Xcode, or use the command-line and CI workflow in [Releasing](releasing.md).

## Product Checks

`./scripts/app.py test` runs the four offline regression harnesses declared in the top-level `testScripts` list in `macos-app.json`: `tools/test_launch_at_login.sh`, `tools/test_login_menu.sh`, `tools/test_multi_display_overlap.sh` and `tools/test_localization.sh`. They cover login-service states, menu actions, localization, display selection, Dock geometry caches, coordinate handling, invalid window records and policy start/stop behavior. Services and window/display snapshots are injected; these checks do not alter real Dock preferences or login items.

For real bilingual menu acceptance against a prebuilt app, use the common native entrypoint:

```sh
./scripts/app.py test --native --case localization \
  --app /Applications/DockAutoHide.app --output /private/tmp/dock-localization-check
```

This check needs an unlocked, idle desktop and existing permissions. It records the visible menus and restores the original language and running state on completion or interruption. See [Localization](localization.md) for prerequisites, evidence and cleanup behavior.

Run an affected isolated harness directly when narrowing a failure; set `VERBOSE=1` for decision logs. Keep results in `TestResults/` or a temporary directory. Check actual Automation authorization, login registration and physical multi-display overlap with the real app when changes affect those system boundaries.

For the windowless app's native shortcut scene regression, use an unlocked desktop
and a fresh output directory:

```sh
./tools/test_shortcuts.sh --output /private/tmp/dock-shortcut-scene-check
```

This compiles the product's actual SwiftUI App scene and delegate with inert Dock,
login and status-menu services. It verifies that Command-comma has no empty
Settings command or window, and retains its fixture, source hashes and menu/window
report. This targeted scene check does not launch the real app, change Dock or
login settings, or establish full product E2E acceptance. It is intentionally
excluded from the default offline test suite. The existing login-menu harness
checks Command-Q mapping, language changes, action dispatch and disabled controls.
