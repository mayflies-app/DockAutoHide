# Releasing

## Configuration

`VERSION` supplies the marketing version. `macos-app.json` configures product `DockAutoHide`, bundle `DockAutoHide.app`, identifier `app.mayfiles.DockAutoHide`, release repository `mayflies-app/DockAutoHide` and cask token `dockautohide`. The configured release repository must match the GitHub repository running the manual workflow.

A command-line `--version` override applies to that build only. Update `VERSION` for a persistent change. GitHub Actions uses the run number for the build number.

## Local Packaging

```sh
./scripts/app.py package
./scripts/app.py package --arch universal --sign developer-id
./scripts/app.py release --dry-run
```

Package defaults to Release, Universal and ad-hoc signing. Select `--arch native|arm64|x86_64|universal`, `--configuration`, `--build`, `--output` and `--sign auto|ad-hoc|developer-id` as needed. Output contains the app in `app/`, a DMG, JSON metadata and a SHA-256 checksum. The staged output is verified before replacing the destination.

Developer ID packaging requires an available Developer ID Application identity, Hardened Runtime and a signing timestamp. Set `MACOS_SIGNING_IDENTITY`, `MACOS_TEAM_ID` and optionally `CODE_SIGN_KEYCHAIN`. Local packaging builds and signs artifacts; it does not submit them to Apple or publish them. Release dry-run displays the complete release plan without executing it.

## GitHub Actions Release

The manual **macOS release** workflow uses the hosted `xcode-27` runner. Its `dry_run` input defaults to `true` and `publish` defaults to `false`. With dry-run disabled, it builds arm64, x86_64 and Universal Developer ID packages, submits them for Apple notarization, staples and validates each DMG, and verifies the mounted app and final checksums. Enable publication only for an explicitly authorized release from a clean, exact source revision.

Configure these repository secrets:

| Purpose | Secrets |
| --- | --- |
| Developer ID certificate | `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD` |
| Signing identity and team | `MACOS_SIGNING_IDENTITY`, `MACOS_TEAM_ID` |
| App Store Connect notarization key | `APPLE_NOTARIZATION_KEY_ID`, `APPLE_NOTARIZATION_ISSUER_ID`, `APPLE_NOTARIZATION_PRIVATE_KEY` |
| Homebrew tap update | `HOMEBREW_TAP_TOKEN` |

`MACOS_CERTIFICATE` is a base64-encoded PKCS#12 certificate; the notarization private key accepts PEM or base64. The notarization issuer ID is the App Store Connect issuer, separate from the signing Team ID.

The workflow uses its GitHub token to publish release assets. The tap token must allow updates to `mayflies-app/homebrew-tap`. A public release requires a public release repository and verified immutable assets.

## Homebrew Distribution

With `publish` enabled, the workflow verifies the public Universal DMG download and updates only `Casks/dockautohide.rb` in [mayflies-app/homebrew-tap](https://github.com/mayflies-app/homebrew-tap). The cask uses the final public DMG checksum, product bundle name and macOS 13.5 requirement.

Homebrew installs the version recorded in the published cask. Local packages and version changes become available there only after a successful authorized publication and cask update. See the tap's [distribution documentation](https://github.com/mayflies-app/homebrew-tap/blob/main/docs/homebrew.md) for the shared release contract.
