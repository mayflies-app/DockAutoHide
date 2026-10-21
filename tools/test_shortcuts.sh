#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[[ $# -eq 2 && "$1" == --output ]] || { echo "Required: --output ABS_NEW_DIRECTORY (visible desktop required)" >&2; exit 2; }
OUTPUT="$(python3 - "$2" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
if not path.is_absolute():
    raise SystemExit("Output must be absolute")
path = path.resolve()
if path.exists():
    raise SystemExit("Output must be a fresh directory")
if not path.parent.is_dir():
    raise SystemExit("Output parent must exist")
print(path)
PY
)"
umask 077
FIXTURE_APP="$OUTPUT/SceneFixture.app"
mkdir -p "$FIXTURE_APP/Contents/MacOS"
cat > "$FIXTURE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SceneFixture</string>
<key>CFBundleIdentifier</key><string>test.DockAutoHide.empty-settings-scene</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>Dock Scene Fixture</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# The actual App scene/delegate run with inert Dock, login and status services.
# This is a targeted native scene regression, not full product E2E acceptance.
git -C "$ROOT" rev-parse HEAD > "$OUTPUT/source-head.txt"
git -C "$ROOT" diff -- DockAutoHide/DockAutoHideApp.swift > "$OUTPUT/source.diff"
shasum -a 256 "$ROOT/DockAutoHide/DockAutoHideApp.swift" "$SCRIPT_DIR/tests/ShortcutSceneAcceptance.swift" > "$OUTPUT/source-sha256.txt"
xcrun swiftc -swift-version 5 -default-isolation MainActor \
  -module-cache-path "${TEST_MODULE_CACHE_PATH:-$OUTPUT/module-cache}" \
  "$ROOT/DockAutoHide/DockAutoHideApp.swift" "$SCRIPT_DIR/tests/ShortcutSceneAcceptance.swift" \
  -o "$FIXTURE_APP/Contents/MacOS/SceneFixture" > "$OUTPUT/compile.log" 2>&1
"$FIXTURE_APP/Contents/MacOS/SceneFixture" "$OUTPUT/scene-shortcuts.json" > "$OUTPUT/scene-shortcuts.log" 2>&1
python3 - "$OUTPUT/scene-shortcuts.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    report = json.load(stream)
if report.get("passed") is not True:
    raise SystemExit("FAIL: empty Settings scene exposes a shortcut or window; see scene-shortcuts.json")
print("isolated native App scene shortcuts passed; real Dock and login mutations: 0")
PY
