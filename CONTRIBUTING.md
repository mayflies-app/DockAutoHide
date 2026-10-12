# Contributing

Focused bug fixes, documentation improvements and reproducible reports are welcome. Discuss substantial product changes before implementing them.

## Setup

Follow [Development](docs/development.md) for the toolchain, command-line workflow and Xcode project. Follow [Localization](docs/localization.md) for UI copy and [Releasing](docs/releasing.md) for packaging.

## Changes

Keep Dock control, overlap geometry, display selection, authorization and login-item policy in product source. Preserve manual control and policy start/stop behavior. Maintain English and Simplified Chinese copy together. Common build and release scripts are maintained in `homebrew-tap/templates/macos-app/scripts` and synchronized here.

## Validation

Run `./scripts/app.py test` and checks appropriate to the change. Reproduce a reported defect before fixing it, and add regression coverage where existing checks leave a meaningful gap. Injected checks use isolated settings and services; they must not change actual Dock preferences or login items. Validate real permissions and physical displays with the actual app when those boundaries are affected.

Do not commit generated output, signing credentials or personal data. Include fresh logs or screenshots for native interaction changes, with sensitive content removed.

## Submission

Describe the user-visible problem, resulting behavior and checks performed. Reports should include the app version, macOS version, Mac architecture and reproduction steps. For security reports, contact [nshcr](https://github.com/nshcr) without posting secrets publicly.

Contributions use the [MIT license](LICENSE). Preserve copyright attribution.
