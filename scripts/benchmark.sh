#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/magv-benchmark.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
PACKAGE_ARGS=(--package-path Packages/MagvCore --scratch-path "$WORK_DIR/Build" --cache-path "$WORK_DIR/Cache" -c release)
swift build --disable-sandbox "${PACKAGE_ARGS[@]}"
BUILD_DIR="$(swift build --disable-sandbox "${PACKAGE_ARGS[@]}" --show-bin-path)"
xcrun swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macos26.0 \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$BUILD_DIR" -I Packages/MagvCore/Vendor/CArchive.xcframework/macos-arm64/Headers \
    -L "$BUILD_DIR" -lMagvCore -larchive -lz -lbz2 -liconv scripts/benchmark.swift -o "$WORK_DIR/benchmark"
if [ "$#" -gt 0 ]; then
    "$WORK_DIR/benchmark" "$@"
else
    "$WORK_DIR/benchmark" --generate "$WORK_DIR/pages"
    python3 - "$WORK_DIR/pages" "$WORK_DIR/synthetic.zip" <<'PY'
import pathlib, sys, zipfile
source = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], 'w', zipfile.ZIP_DEFLATED) as archive:
    for page in source.glob('*.png'):
        archive.write(page, page.name)
PY
    "$WORK_DIR/benchmark" "$WORK_DIR/pages" "$WORK_DIR/synthetic.zip"
fi
