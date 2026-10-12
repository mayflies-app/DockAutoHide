#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dock-localization-regression.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FIXTURE_APP="$WORK/Regression.app"
mkdir -p "$FIXTURE_APP/Contents/MacOS" "$FIXTURE_APP/Contents/Resources"
cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/zh-Hans.lproj" "$FIXTURE_APP/Contents/Resources/"
cat > "$FIXTURE_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>localization-regression</string>
<key>CFBundleIdentifier</key><string>test.DockAutoHide.localization-regression</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
</dict></plist>
PLIST
TARGET_ARCH="${TEST_ARCH:-$(uname -m)}"
case "${TARGET_ARCH}" in
  arm64 | x86_64) ;;
  *) echo "Unsupported test architecture: ${TARGET_ARCH}" >&2; exit 1 ;;
esac
xcrun swiftc -swift-version 5 -default-isolation MainActor -module-name DockLocalizationRegression -target "${TARGET_ARCH}-apple-macos13.5" -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -module-cache-path "$WORK/module-cache" \
  "$ROOT/DockAutoHide/AppSettings.swift" "$ROOT/DockAutoHide/LocalizationResources.swift" "$ROOT/DockAutoHide/DockLogger.swift" \
  "$ROOT/DockAutoHide/DockPreferencesClient.swift" "$ROOT/DockAutoHide/DockWindowOverlapEvaluator.swift" \
  "$ROOT/DockAutoHide/SmartPolicyEngine.swift" "$ROOT/DockAutoHide/DockManager.swift" \
  "$ROOT/DockAutoHide/LaunchAtLoginManager.swift" "$ROOT/DockAutoHide/MenuBarManager.swift" \
  "$SCRIPT_DIR/tests/LocalizationRegression.swift" -o "$FIXTURE_APP/Contents/MacOS/localization-regression"
"$FIXTURE_APP/Contents/MacOS/localization-regression" > "$WORK/result.log"
cat "$WORK/result.log"
if ! /usr/bin/grep -q '^isolated localization regressions passed ' "$WORK/result.log"; then
  echo "Localization regression exited without completing; rerun with access to macOS window services." >&2
  exit 1
fi
