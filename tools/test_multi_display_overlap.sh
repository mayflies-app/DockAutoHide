#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dock-auto-hide-multi-display.XXXXXX")"

cleanup() {
  rm -rf "${BUILD_DIR}"
}
trap cleanup EXIT

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
TARGET_ARCH="${TEST_ARCH:-$(uname -m)}"
case "${TARGET_ARCH}" in
  arm64 | x86_64) ;;
  *)
    echo "Unsupported test architecture: ${TARGET_ARCH}" >&2
    exit 1
    ;;
esac

xcrun swiftc \
  -module-name DockAutoHideMultiDisplayRegression \
  -target "${TARGET_ARCH}-apple-macos13.5" \
  -sdk "${SDK_PATH}" \
  -module-cache-path "${BUILD_DIR}/module-cache" \
  "${REPO_ROOT}/DockAutoHide/DockLogger.swift" \
  "${REPO_ROOT}/DockAutoHide/DockPreferencesClient.swift" \
  "${REPO_ROOT}/DockAutoHide/DockWindowOverlapEvaluator.swift" \
  "${REPO_ROOT}/DockAutoHide/SmartPolicyEngine.swift" \
  "${SCRIPT_DIR}/tests/MultiDisplayOverlapRegression.swift" \
  -o "${BUILD_DIR}/multi-display-regression"

"${BUILD_DIR}/multi-display-regression"
