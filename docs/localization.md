# Localization

## Supported Languages

The app supports English (`en`) and Simplified Chinese (`zh-Hans`). Language choices use their own names: **English** and **简体中文**. On first launch, the first supported language in macOS preference order wins; English is the fallback.

## Runtime Behavior

**Interface Language** stores an explicit selection immediately. Existing menus, status rows, app-generated errors, tooltips and accessibility labels update without relaunching. Language changes preserve Dock policy, Dock preferences and login-item state. macOS permission dialogs use the system language.

## Adding UI Copy

Runtime translations live in `Resources/en.lproj/Localizable.strings` and `Resources/zh-Hans.lproj/Localizable.strings`. Add a semantic key to `AppText` in `DockAutoHide/AppSettings.swift` and supply the same key in both tables. Swift contains keys and presentation behavior, not translated interface copy. Language names retain their native names.

`LocalizationResources` resolves the explicitly selected language from the app bundle, accepts Xcode's and SwiftPM's localization-directory casing, falls back to English for a missing key, and returns the key if neither table defines it. Resolve keys when presenting them so retained app-generated errors follow the selected language. System error descriptions keep the language supplied by macOS.

Bundle display strings and Automation permission descriptions live in each language's `InfoPlist.strings`. Use `DockAutoHide` for product and bundle identity, **Dock Auto Hide** for English display text and **Dock 自动隐藏** for Chinese display text. Keep format arguments consistent across translations. The Xcode target copies both localized tables into the app's `Contents/Resources` directory; the command-line build uses the same Xcode target.

## Validation

Run `./scripts/app.py test`. This common entrypoint invokes the existing `tools/test_localization.sh` resource checks. Their isolated fixture uses the same app-bundle resource layout and checks exact bilingual key coverage, app metadata, English fallback, system preference ordering, unsupported-language fallback, saved selections, existing menu and error updates, tooltips and accessibility labels. Injected boundaries verify that changing language makes no Dock, permission or login-item mutations. The visible-menu check uses the same native localization command as the other apps:

```sh
./scripts/app.py test --native --case localization \
  --app /Applications/DockAutoHide.app \
  --output /private/tmp/dock-localization-check --timeout-seconds 120
```

Use a prebuilt app and a new or empty output directory with an existing writable parent. Run on an unlocked desktop with existing Accessibility, event-posting and Screen Recording permissions. Complete the app's normal first-launch permission setup beforehand. Automatic test launch requires a saved manual Dock setting matching the current Dock auto-hide setting; otherwise launch the app normally before testing. This check does not request permissions or operate authorization, Dock-policy or login controls. Leave the mouse and keyboard idle while the menus are inspected.

The check clicks the live status-icon frame, opens the actual language submenu, selects both languages without restarting, and verifies visible rows, status, version, accessibility text and selection marks. PNG screenshots and AX snapshots accompany `localization-flow.json`; the shared recorder writes `manifest.json`, logs, source fingerprints and bundle fingerprints. Acceptance requires both reports to pass.

Success, assertion failure, timeout, SIGINT and SIGTERM take the same bounded cleanup path. The check restores the original language selection and exact persisted language key, including an absent key, and compares the complete app preference snapshot and Dock user settings. Dock's volatile `mod-count` bookkeeping counter is retained in evidence but excluded from the equality check; it is never rewritten. It preserves the original app process when already running and otherwise requests normal termination after verification. It never force-quits the app or overwrites non-language settings. Evidence directories are private because preference snapshots may contain user-specific values. An interrupted run reports failure even when restoration succeeds; inspect the restoration fields before retrying.
