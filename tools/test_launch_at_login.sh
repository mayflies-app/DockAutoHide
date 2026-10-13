#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dock-login-regression.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FIXTURE_APP="$WORK/Regression.app"
mkdir -p "$FIXTURE_APP/Contents/MacOS" "$FIXTURE_APP/Contents/Resources"
cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/zh-Hans.lproj" "$FIXTURE_APP/Contents/Resources/"
cat > "$FIXTURE_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>login-regression</string>
<key>CFBundleIdentifier</key><string>test.DockAutoHide.login-regression</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
</dict></plist>
PLIST
TARGET_ARCH="${TEST_ARCH:-$(uname -m)}"
case "${TARGET_ARCH}" in
  arm64 | x86_64) ;;
  *)
    echo "Unsupported test architecture: ${TARGET_ARCH}" >&2
    exit 1
    ;;
esac
xcrun swiftc -module-name DockLoginRegression -target "${TARGET_ARCH}-apple-macos13.5" -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -module-cache-path "${TEST_MODULE_CACHE_PATH:-$WORK/module-cache}" "$ROOT/DockAutoHide/DockLogger.swift" \
  "$ROOT/DockAutoHide/AppSettings.swift" "$ROOT/DockAutoHide/LocalizationResources.swift" "$ROOT/DockAutoHide/LaunchAtLoginManager.swift" "$SCRIPT_DIR/tests/LaunchAtLoginRegression.swift" \
  -o "$FIXTURE_APP/Contents/MacOS/login-regression"
"$FIXTURE_APP/Contents/MacOS/login-regression"
