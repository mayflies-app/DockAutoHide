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

The manual **macOS release** workflow uses the common `./scripts/app.py release` entrypoint. Its `dry_run` input defaults to `true` and `publish` defaults to `false`. With dry-run disabled, it builds one Universal Developer ID package containing arm64 and x86_64, submits its DMG for Apple notarization, staples and validates that DMG, and verifies the mounted app and final checksums. Enable publication only for an explicitly authorized release from a clean, exact source revision.

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

Dry-run uses the `preview` job on `ubuntu-latest`, without credentials or build-cache access. Execution follows `preflight → package → notarize → publish → cask`, using the common `./scripts/app.py release --execute --stage <job>` entrypoint. `package` and `notarize` use GitHub-hosted `xcode-27` with Xcode 27; the other jobs use `ubuntu-latest`. Signing secrets are scoped to `package`, notarization secrets and Team ID to `notarize`, Contents write to `publish`, and `HOMEBREW_TAP_TOKEN` to `cask`. `publish=false` stops after notarization. A matching public version reuses verified public assets and skips rebuilding and notarization. Release runs are serialized and never cancel an in-progress execution.

Use **Re-run failed jobs** or re-run a failed job itself to reuse successful upstream work. Jobs download immutable inputs by the producer's artifact ID; the signed app travels in a tar archive preserving executable modes and symlinks. Notarization resumes a retained submission ID after checking the original DMG checksum. Draft publication verifies existing bytes and uploads only missing assets. Empty `starter` placeholders from failed uploads are removed only after all completed assets pass byte verification; an already published release is verified without further writes. Missing artifact IDs stop before download, without falling back to all artifacts. A cask retry only verifies public assets and updates the tap. Build cache saving completes in `package` even if a later job fails.

Keep workflow artifacts until completion. Expired inputs require a new run. If a prior notary execution has no retained submission ID, inspect Apple submission history before starting a new workflow run. Re-running all jobs can produce different signed bytes that cannot reuse the previous checkpoint. See [shared release retries](https://github.com/mayflies-app/homebrew-tap/blob/main/docs/homebrew.md#retry-a-failed-job) for recovery boundaries. Ordinary CI retains tests, bundle builds and release-plan checks.

Debug and Release compilation caches are separate. Keys include actual Xcode, SDK and Swift fingerprints, build configuration, dependency/configuration hashes and the source SHA; fallback stays within the same compiler and dependency prefix. Cache paths exclude `dist` and credentials. Pull requests restore only; successful branch pushes may save Debug caches within GitHub's branch scope. Release dispatches on the default branch may save Release caches. Release cache hits and packaging timings require an executed release; dry-run previews do not exercise the Release compilation cache.

Tracked-input timestamps are reused only when content hashes, modes and checkout paths match the saved cache. Asset catalog and icon directory timestamps require an identical complete tracked tree. Changed inputs still rebuild. Xcode builds on GitHub Actions disable the SDK file-status index; local builds retain Xcode's default. Ordinary regression scripts share SDK compiler modules inside the existing build cache; fixtures and test execution are created afresh.

## Homebrew Distribution

With `publish` enabled, the workflow verifies the public Universal DMG download and updates only `Casks/dockautohide.rb` in [mayflies-app/homebrew-tap](https://github.com/mayflies-app/homebrew-tap). The cask uses the final public DMG checksum, product bundle name and macOS 13.5 requirement.

Homebrew installs the version recorded in the published cask. Local packages and version changes become available there only after a successful authorized publication and cask update. See the tap's [distribution documentation](https://github.com/mayflies-app/homebrew-tap/blob/main/docs/homebrew.md) for the shared release contract.

## Release Diagnostics

Release logs identify stages, failure kinds and external exit codes, with credential-safe
GitHub error annotations. See [shared release diagnostics](https://github.com/mayflies-app/homebrew-tap/blob/main/docs/homebrew.md#release-diagnostics)
for authentication, authorization, repository access, network, concurrency and validation errors.
Tap updates use `HOMEBREW_TAP_TOKEN`, separately from the app workflow token.

A tap failure after successful publication leaves the release assets published. Repair
the cask from those verified public assets; do not rebuild or replace the same version.
Only confirmed concurrent push rejection is rebased and retried.
