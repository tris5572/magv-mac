#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/magv-tests.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
PACKAGE_ARGS=(--package-path Packages/MagvCore --scratch-path "$WORK_DIR/Build" --cache-path "$WORK_DIR/Cache")
# --disable-sandbox is for SwiftPM's nested build sandbox, not the app's App Sandbox.
swift test --disable-sandbox "${PACKAGE_ARGS[@]}"
BUILD_DIR="$(swift build --disable-sandbox "${PACKAGE_ARGS[@]}" --show-bin-path)"
xcrun swiftc -disable-sandbox -parse-as-library -swift-version 6 -target arm64-apple-macos26.0 \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$BUILD_DIR" -I Packages/MagvCore/Vendor/CArchive.xcframework/macos-arm64/Headers \
    -L "$BUILD_DIR" -lMagvCore -larchive -lz -lbz2 -liconv \
    magv-mac/ReaderPreferencesStore.swift magv-mac/ReaderSession.swift magv-mac/InputRouter.swift \
    magv-mac/RenameSheetController.swift magv-mac/ImageCanvas.swift scripts/session-smoke.swift \
    -o "$WORK_DIR/session-smoke"
"$WORK_DIR/session-smoke" "$REPO_ROOT/Packages/MagvCore/Tests/MagvCoreTests/Fixtures" "$@"
