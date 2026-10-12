#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dock-login-menu-regression.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -module-name DockLoginMenuRegression -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -module-cache-path "$WORK/module-cache" "$ROOT/DockAutoHide/DockLogger.swift" \
  "$ROOT/DockAutoHide/LaunchAtLoginManager.swift" "$ROOT/DockAutoHide/MenuBarManager.swift" \
  "$SCRIPT_DIR/tests/LoginMenuRegression.swift" -o "$WORK/login-menu-regression"
"$WORK/login-menu-regression"
