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

The manual **macOS release** workflow uses the common `./scripts/app.py release` entrypoint. Its `dry_run` input defaults to `true` and `publish` defaults to `false`. With dry-run disabled, it builds one Universal Developer ID package containing arm64 and x86_64, submits its DMG once for Apple notarization, staples and validates that DMG, and verifies the mounted app and final checksums. Enable publication only for an explicitly authorized release from a clean, exact source revision.

Configure these repository secrets:

| Purpose | Secrets |
| --- | --- |
| Developer ID certificate | `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD` |
| Signing identity and team | `MACOS_SIGNING_IDENTITY`, `MACOS_TEAM_ID` |
| App Store Connect notarization key | `APPLE_NOTARIZATION_KEY_ID`, `APPLE_NOTARIZATION_ISSUER_ID`, `APPLE_NOTARIZATION_PRIVATE_KEY` |
| Homebrew tap update | `HOMEBREW_TAP_TOKEN` |

`MACOS_CERTIFICATE` is a base64-encoded PKCS#12 certificate; the notarization private key accepts PEM or base64. The notarization issuer ID is the App Store Connect issuer, separate from the signing Team ID.

The workflow uses its GitHub token to publish release assets. The tap token must allow updates to `mayflies-app/homebrew-tap`. A public release requires a public release repository and verified immutable assets.

### Cache and Execution

Dry-run uses a dedicated `ubuntu-latest` preview job without Xcode, signing credentials or build-cache access. Execution uses the GitHub-hosted `xcode-27` runner. Release jobs are serialized and never cancel an in-progress release. Ordinary CI cancels superseded runs and retains tests, bundle builds and release-plan checks.

Debug and Release compilation caches are separate. Keys include actual Xcode, SDK and Swift fingerprints, build configuration, dependency/configuration hashes and the source SHA; fallback stays within the same compiler and dependency prefix. Cache paths exclude `dist` and credentials. Pull requests restore only; successful branch pushes may save Debug caches within GitHub's branch scope. Release dispatches on the default branch may save Release caches. Release cache hits and packaging timings require an executed release; dry-run previews do not exercise the Release compilation cache.

Tracked-input timestamps are reused only when content hashes, modes and checkout paths match the saved cache. Asset catalog and icon directory timestamps require an identical complete tracked tree. Changed inputs still rebuild. Xcode builds on GitHub Actions disable the SDK file-status index; local builds retain Xcode's default. Ordinary regression scripts share SDK compiler modules inside the existing build cache; fixtures and test execution are created afresh.

## Homebrew Distribution

With `publish` enabled, the workflow verifies the public Universal DMG download and updates only `Casks/dockautohide.rb` in [mayflies-app/homebrew-tap](https://github.com/mayflies-app/homebrew-tap). The cask uses the final public DMG checksum, product bundle name and macOS 13.5 requirement.

Homebrew installs the version recorded in the published cask. Local packages and version changes become available there only after a successful authorized publication and cask update. See the tap's [distribution documentation](https://github.com/mayflies-app/homebrew-tap/blob/main/docs/homebrew.md) for the shared release contract.
