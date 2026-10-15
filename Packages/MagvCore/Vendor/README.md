# libarchive 3.8.10

- Upstream: https://github.com/libarchive/libarchive/releases/tag/v3.8.10
- Source: https://www.libarchive.org/downloads/libarchive-3.8.10.tar.xz
- SHA-256: `56cad765459d5ee25a3b761f90c47d99379d28297fbfb72d908880d6b875fb96`
- Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/rebuild-libarchive.sh`
- Binary: static arm64, minimum macOS 26.0; Xcode/Apple clang, `-O2`.
- Runtime dependencies: macOS system zlib, bz2, iconv, libc, CommonCrypto. No bundled executables, Homebrew libraries, JavaScript, WASM, or system libarchive.
- Enabled in MagvCore: ZIP (Stored/Deflate, ZIP64), RAR and RAR5 readers; no outer compression filters or subprocess fallbacks.
- Legacy ZIP names without a UTF-8 flag use CP932. Unicode ZIP flags retain priority.
- Other compression variants remain dependent on this build's capabilities and report an error.
- RAR solid is verified for the RAR5 fixture. RAR4 solid and all real-world manga variants are not yet qualified.
- License: `COPYING`; full source copyright notices also ship in the app's `ThirdPartyNotices.txt`.

The checked-in XCFramework is ready for offline builds. `LIBARCHIVE_TARBALL=/path/to/libarchive-3.8.10.tar.xz` allows offline rebuilding after checksum verification. Intel slices are not included in this prototype.
