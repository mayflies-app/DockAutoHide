# Contributing

Focused bug fixes, documentation improvements and reproducible reports are welcome. Discuss substantial product changes before implementing them.

## Setup

Follow [Development](docs/development.md) for the toolchain, command-line workflow and Xcode project. Follow [Localization](docs/localization.md) for UI copy and [Releasing](docs/releasing.md) for packaging.

## Changes

Keep Dock control, overlap geometry, display selection, authorization and login-item policy in product source. Preserve manual control and policy start/stop behavior. Maintain English and Simplified Chinese copy together.

Shared scripts, workflows, and declared design and localization helpers are maintained in `homebrew-tap/templates/macos-app`. This repository declares its repository-relative helper destinations in the `shared` object of `macos-app.json`; app configuration, translations, product behavior and targeted checks belong here. Update shared implementation in the tap and synchronize from its root with explicit app checkout arguments after reviewing local and staged changes. Do not commit host-specific paths or assume a workspace layout. See [Shared Maintenance](https://github.com/mayflies-app/homebrew-tap/tree/main/templates/macos-app#shared-maintenance).

## Validation

Match validation to the change. For documentation only, check links, referenced paths and `git diff --check`; no app build or product test is needed. For executable changes, run `./scripts/app.py test` and the affected checks in [Development](docs/development.md). Build, package or inspect native UI only when the change affects those behaviors.

Reproduce a reported defect before fixing it, and add regression coverage where existing checks leave a meaningful gap. Injected checks use isolated settings and services; they must not change actual Dock preferences or login items. Validate real permissions and physical displays with the actual app when those boundaries are affected.

Do not commit generated output, signing credentials or personal data. Include fresh logs or screenshots for native interaction changes, with sensitive content removed.

## Submission

Describe the user-visible problem, resulting behavior and checks performed. Reports should include the app version, macOS version, Mac architecture and reproduction steps. For security reports, contact [nshcr](https://github.com/nshcr) without posting secrets publicly.

Contributions use the [MIT license](LICENSE). Preserve copyright attribution.
