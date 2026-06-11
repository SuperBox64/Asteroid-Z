#!/usr/bin/env bash
# Boss-Man, SpriteKit edition, build helper. Wraps `swift build` with the
# swift.org toolchain + wasm SDK env so wasm32-wasip1 actually finds the
# C target (KitABI shim.c + Box2DBridge cbox2d.cpp) — Xcode's bundled clang
# has no wasm backend, so we run through xcrun --toolchain swift to pick the
# swift.org clang the wasm SDK was built against.
#
# Usage:
#   ./build.sh                  # debug
#   ./build.sh release          # release
#   ./build.sh --target AsteroidZ # forwarded to swift build

set -eo pipefail

# The runtime lives in its OWN repo, a sibling of the AsteroidZ repo (never a
# nested clone inside it). Dev: ../../WasmKit is the working
# checkout and is used as-is. CI: cloned to that same spot, outside the repo.
# Resolved from the script's location so the clone target never depends on
# the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WASMKIT="$SCRIPT_DIR/../../WasmKit"
if [ ! -d "$WASMKIT" ]; then
  echo "→ Cloning WasmKit..."
  git clone https://github.com/SuperBox64/WasmKit "$WASMKIT"
fi

SWIFT_TOOLCHAIN="${SWIFT_TOOLCHAIN:-org.swift.6.3.2-release}"
WASM_SDK="${WASM_SDK:-swift-6.3.2-RELEASE_wasm}"

CONFIG_ARGS=()
PASSTHROUGH=()
for arg in "$@"; do
  case "$arg" in
    release) CONFIG_ARGS=(-c release -Xswiftc -Osize -Xlinker -s -Xswiftc -Xfrontend -Xswiftc -disable-reflection-metadata) ;;  # -Osize + strip + drop reflection field metadata (Mirror only; conformance/cast metadata kept). LTO/hermetic-seal externalize the runtime DSO-image hook and break wasm instantiation
    debug)   CONFIG_ARGS=(-c debug)   ;;
    *)       PASSTHROUGH+=("$arg")    ;;
  esac
done

echo "→ swift build  (toolchain=$SWIFT_TOOLCHAIN  sdk=$WASM_SDK)"
TOOLCHAINS="$SWIFT_TOOLCHAIN" \
  xcrun --toolchain swift swift build \
  --swift-sdk "$WASM_SDK" \
  "${CONFIG_ARGS[@]}" \
  "${PASSTHROUGH[@]}"

# Auto-publish into web/ when building release so the page is one curl away.
if [ "${CONFIG_ARGS[1]:-}" = "release" ]; then
  REL=.build/wasm32-unknown-wasip1/release/AsteroidZ.wasm
  if command -v wasm-opt >/dev/null 2>&1; then
    # wasm-opt -Oz reads the binary's own target_features section, so it only
    # emits instructions the current runtime already supports. Squeezes a few
    # more % out after the compiler's -Osize + wasm-ld --gc-sections dead-strip.
    wasm-opt -Oz \
      --enable-bulk-memory --enable-nontrapping-float-to-int \
      --enable-sign-ext --enable-mutable-globals --enable-multivalue \
      "$REL" -o web/asteroidz.wasm
    echo
    echo "✓ Release artifact published (wasm-opt -Oz): web/asteroidz.wasm"
  else
    cp "$REL" web/asteroidz.wasm
    echo
    echo "✓ Release artifact published (install binaryen for a smaller wasm): web/asteroidz.wasm"
  fi
else
  cp .build/wasm32-unknown-wasip1/debug/AsteroidZ.wasm web/asteroidz.wasm
  echo
  echo "✓ Debug artifact published: web/asteroidz.wasm"
fi

source "$WASMKIT/build.sh"
wasmweb_manifest web/assets web/manifest.json
rm -f web/runtime.js web/runtime-embedded-min.js
cp "$WASMKIT/runtime.js" web/runtime.js
# Minified runtime used by the Embedded build + the website (smaller, same behavior).
cp "$WASMKIT/runtime-embedded-min.js" web/runtime-embedded-min.js
