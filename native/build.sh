#!/bin/bash
# Embedded Swift NATIVE host build - the same Embedded mode as the game wasm.
# No Swift stdlib, no Foundation; SDL3 + wasmtime C API through Swift interop.
set -euo pipefail
cd "$(dirname "$0")"
TOOLCHAINS="${SWIFT_TOOLCHAIN:-org.swift.6.3.2-release}" xcrun --toolchain swift swiftc \
  -enable-experimental-feature Embedded -wmo -Osize -parse-as-library \
  -Xcc -fmodule-map-file=Sources/CSDL3/module.modulemap \
  -Xcc -fmodule-map-file=Sources/CWasmtime/module.modulemap \
  -Xcc -I/opt/homebrew/include -I Sources/CSDL3 -I Sources/CWasmtime \
  -L /opt/homebrew/lib -lSDL3 -lwasmtime \
  "$(dirname "$(dirname "$(TOOLCHAINS=${SWIFT_TOOLCHAIN:-org.swift.6.3.2-release} xcrun --toolchain swift -f swiftc)")")/lib/swift/embedded/arm64-apple-macos/libswiftUnicodeDataTables.a" \
  Sources/AsteroidZNative/main.swift -o asteroidz-native
echo "✓ asteroidz-native ($(stat -f%z asteroidz-native) bytes, Embedded Swift host)"
