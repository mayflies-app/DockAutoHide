#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Arguments select the real-desktop case; no arguments retain isolated regressions.
if [[ $# -gt 0 ]]; then
  APP=""
  OUTPUT=""
  CASE_NAME="localization"
  TIMEOUT_SECONDS=120
  SEEN=" "
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app|--output|--case|--timeout-seconds)
        [[ "$SEEN" != *" $1 "* && $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "Invalid or duplicate argument: $1" >&2; exit 2; }
        SEEN+="$1 "
        case "$1" in
          --app) APP="$2" ;;
          --output) OUTPUT="$2" ;;
          --case) CASE_NAME="$2" ;;
          --timeout-seconds) TIMEOUT_SECONDS="$2" ;;
        esac
        shift 2
        ;;
      *) echo "Unknown localization argument: $1" >&2; exit 2 ;;
    esac
  done
  [[ "$CASE_NAME" == localization && -n "$APP" && -n "$OUTPUT" ]] || { echo "Required: --app ABS.app --output ABS_DIRECTORY --case localization" >&2; exit 2; }
  RECORDER_TIMEOUT="$(python3 - "$ROOT" "$APP" "$OUTPUT" "$TIMEOUT_SECONDS" <<'PY'
import math
import os
from pathlib import Path
import plistlib
import re
import sys
try:
    repo, app_input, output_input = map(Path, sys.argv[1:4])
    number = sys.argv[4]
    if not re.fullmatch(r"(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)", number):
        raise ValueError("timeout must be a positive decimal")
    timeout = float(number)
    if not math.isfinite(timeout) or not 0 < timeout <= 86335:
        raise ValueError("timeout must be in (0, 86335], reserving 65 seconds for restoration")
    if not app_input.is_absolute() or not output_input.is_absolute():
        raise ValueError("app and output must be absolute paths")
    app = app_input.resolve(strict=True)
    if not app.is_dir() or app.suffix != '.app':
        raise ValueError("app must be an existing app directory")
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'app.mayfiles.DockAutoHide' or info.get('CFBundleExecutable') != 'DockAutoHide' or info.get('CFBundlePackageType') != 'APPL':
        raise ValueError("app must be a DockAutoHide app bundle")
    binary = (app / 'Contents/MacOS/DockAutoHide').resolve(strict=True)
    if not binary.is_relative_to(app) or not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("app executable must be contained and executable")
    output = output_input.resolve()
    cache = (repo / '.build/native-verification').resolve()
    forbidden = [app, repo / '.git', cache]
    if any(output == item or output.is_relative_to(item) for item in forbidden) or cache.is_relative_to(output):
        raise ValueError("output overlaps the bundle, Git metadata or compiler cache")
    if output.exists():
        if not output.is_dir() or any(output.iterdir()) or not os.access(output, os.W_OK):
            raise ValueError("output must be new or empty and writable")
    elif not output.parent.is_dir() or not os.access(output.parent, os.W_OK):
        raise ValueError("output parent must exist and be writable")
    print(timeout + 65)
except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
    print(f"test_localization: {error}", file=sys.stderr)
    sys.exit(2)
PY
)"
  # Preference snapshots may contain user-specific values; keep all evidence private.
  umask 077
  CACHE="$ROOT/.build/native-verification"
  mkdir -p "$CACHE"
  xcrun swiftc -swift-version 5 -module-cache-path "$CACHE/ModuleCache" \
    "$SCRIPT_DIR/tests/LocalizationMenuAcceptance.swift" -o "$CACHE/LocalizationMenuAcceptance"
  xcrun swiftc -module-cache-path "$CACHE/ModuleCache" \
    "$ROOT/scripts/lib/VerificationEvidence.swift" -o "$CACHE/VerificationEvidence"
  exec "$CACHE/VerificationEvidence" --project DockAutoHide --repo "$ROOT" --app "$APP" --output "$OUTPUT" \
    --expected-bundle-id app.mayfiles.DockAutoHide --report "$OUTPUT/localization-flow.json" \
    --success-field passed --timeout-seconds "$RECORDER_TIMEOUT" --termination-grace-seconds 60 \
    -- "$CACHE/LocalizationMenuAcceptance" --app "$APP" --output "$OUTPUT" --timeout-seconds "$TIMEOUT_SECONDS"
fi

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
  -module-cache-path "${TEST_MODULE_CACHE_PATH:-$WORK/module-cache}" \
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
