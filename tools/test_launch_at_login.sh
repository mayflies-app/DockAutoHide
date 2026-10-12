#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dock-login-regression.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -module-name DockLoginRegression -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -module-cache-path "$WORK/module-cache" "$ROOT/DockAutoHide/DockLogger.swift" \
  "$ROOT/DockAutoHide/LaunchAtLoginManager.swift" "$SCRIPT_DIR/tests/LaunchAtLoginRegression.swift" \
  -o "$WORK/login-regression"
"$WORK/login-regression"
