#!/bin/bash
set -euo pipefail
# 同梱のApple Silicon用ライブラリを、Homebrewに依存せず再ビルドする。
# 固定バージョンの公式ソースだけを取得する。オフライン時はLIBARCHIVE_TARBALLで指定する。
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=3.8.10
SHA256=56cad765459d5ee25a3b761f90c47d99379d28297fbfb72d908880d6b875fb96
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/magv-libarchive.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
TARBALL="${LIBARCHIVE_TARBALL:-$WORK_DIR/libarchive.tar.xz}"
if [[ ! -f "$TARBALL" ]]; then
    curl -fL "https://www.libarchive.org/downloads/libarchive-$VERSION.tar.xz" -o "$TARBALL"
fi
# 展開前にハッシュを照合し、固定したソースと同一であることを確認する。
printf '%s  %s\n' "$SHA256" "$TARBALL" | shasum -a 256 -c -
tar -xf "$TARBALL" -C "$WORK_DIR"
cd "$WORK_DIR/libarchive-$VERSION"
# ソリッドRAR5の画像本体を展開せず一覧を取得できるよう、専用パッチを適用する。
patch -p1 < "$REPO_ROOT/Packages/MagvCore/Vendor/rar5-index-only.patch"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun -f clang)"
export CFLAGS="-arch arm64 -mmacosx-version-min=26.0 -O2"
export LDFLAGS="-arch arm64 -mmacosx-version-min=26.0"
# 実行コマンドや不要な外部依存を除き、アプリに組み込む静的ライブラリだけを作る。
./configure --disable-shared --enable-static --disable-bsdtar --disable-bsdcat \
    --disable-bsdcpio --disable-bsdunzip --disable-dependency-tracking \
    --without-lz4 --without-zstd --without-lzma --without-lzo2 --without-libb2 \
    --without-openssl --without-nettle --without-mbedtls --without-xml2 \
    --without-expat --without-bsdxml --without-xmllite
make -j4 libarchive.la
mkdir "$WORK_DIR/Headers"
cp libarchive/archive.h libarchive/archive_entry.h "$WORK_DIR/Headers/"
cat > "$WORK_DIR/Headers/module.modulemap" <<'MODULE'
module CArchive {
    header "archive.h"
    header "archive_entry.h"
    export *
}
MODULE
xcodebuild -create-xcframework -library "$PWD/.libs/libarchive.a" \
    -headers "$WORK_DIR/Headers" -output "$WORK_DIR/CArchive.xcframework"
# 再ビルドがすべて成功した後にだけ、同梱ライブラリを置き換える。
rm -rf "$REPO_ROOT/Packages/MagvCore/Vendor/CArchive.xcframework"
cp -R "$WORK_DIR/CArchive.xcframework" "$REPO_ROOT/Packages/MagvCore/Vendor/"
cp COPYING "$REPO_ROOT/Packages/MagvCore/Vendor/COPYING"
# 再ビルドしたソースから、同梱ライブラリのライセンス表記も更新する。
python3 - "$PWD" "$REPO_ROOT/magv-mac/ThirdPartyNotices.txt" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
notices = [(root/'COPYING').read_text()]
for p in sorted((root/'libarchive').iterdir()):
    if p.suffix not in ('.c', '.h'): continue
    text = p.read_text(errors='replace')
    if text.startswith('/*'):
        notices.append('\n--- '+p.name+' ---\n'+text[:text.find('*/')+2])
Path(sys.argv[2]).write_text('\n'.join(notices))
PY
