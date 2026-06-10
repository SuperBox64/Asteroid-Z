#!/usr/bin/env bash
# Build AsteroidZ as an Embedded-Swift wasm (same pipeline and flags as Boss-Man).
#
# Proven pipeline: every framework module + the 48-file game compile under
# -enable-experimental-feature Embedded, link with Box2D v3 (pure C) + the
# embedded stdlib + WASI libc, and boot in the stock runtime.js (rendering the
# title screen identically to the normal build). No C++ anywhere in the link.
#
# Prereqgs: swift 6.3.2 toolchain, the swift-6.3.2-RELEASE_wasm SDK, wasm-opt.
# Run a normal `./build.sh release` in boss-man-spritekit-web first so the C
# objects (KitABI shim.c) are already compiled for wasm.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Framework: local sibling checkout (dev) or the SwiftPM checkout (CI).
FW="$(cd "$ROOT/../superbox64-spritekit" 2>/dev/null && pwd || true)"
[ -d "$FW/Sources/SpriteKit" ] || FW="$(find "$ROOT/asteroidz-web/.build" -maxdepth 3 -type d -name superbox64-spritekit 2>/dev/null | head -1)"
GAMESRC="$ROOT/asteroidz-web/Sources/AsteroidZ"
# Derive the toolchain + wasm SDK locations (portable: works locally and in CI).
TC="$(dirname "$(dirname "$(xcrun --toolchain swift -f swiftc)")")"   # .../usr/bin/swiftc -> .../usr -> toolchain/usr
TC="${TC%/usr}"                                                        # -> .../<toolchain>.xctoolchain
SDK="$(dirname "$(find "$HOME/Library/org.swift.swiftpm/swift-sdks" -type d -name "wasm32-unknown-wasip1" 2>/dev/null | head -1)")/wasm32-unknown-wasip1"
SYSLIB="$SDK/WASI.sdk/lib/wasm32-wasip1"
UNI="$(find "$TC/usr/lib/swift/embedded/wasm32-unknown-none-wasm" -name libswiftUnicodeDataTables.a | head -1)"
WASMLD="$TC/usr/bin/wasm-ld"
CLANG="$(find "$TC" -name clang | head -1)"
B="$(mktemp -d)"; mkdir -p "$B/src" "$B/mod"

# @MainActor isn't vended by the Embedded stdlib (single-threaded wasm). Strip it
# (and the `{ @MainActor in` closure form) at preprocess time; drop the per-target
# .defaultIsolation(MainActor.self) by building with raw swiftc (no SwiftPM).
strip() { sed -e 's/{ @MainActor in/{/g' -e 's/@MainActor //g' -e 's/@MainActor//g' "$1"; }

# CBox2D's public headers pull libc headers (math.h/stdint.h); the bare-metal
# Embedded target has no sysroot, so point the ClangImporter at wasi-libc's.
SYSINC="$SDK/WASI.sdk/include/wasm32-wasip1"
EMB=(-enable-experimental-feature Embedded -wmo -Osize -parse-as-library
     -target wasm32-unknown-none-wasm
     -Xcc -fmodule-map-file="$FW/Sources/KitABI/include/module.modulemap"
     -Xcc -fmodule-map-file="$FW/Sources/CBox2D/include/module.modulemap"
     -Xcc -isystem -Xcc "$SYSINC"
     -I "$FW/Sources/KitABI/include" -I "$FW/Sources/CBox2D/include" -I "$B/mod")

build_mod() {            # module name (deps already in $B/mod)
  local m="$1"; mkdir -p "$B/src/$m"
  for f in "$FW/Sources/$m"/*.swift; do strip "$f" > "$B/src/$m/$(basename "$f")"; done
  xcrun --toolchain swift swiftc "${EMB[@]}" -emit-module \
    -emit-module-path "$B/mod/$m.swiftmodule" -module-name "$m" \
    -c "$B/src/$m"/*.swift -o "$B/mod/$m.o"
}

echo "→ framework modules (dependency order)"
for m in SpriteKit AppKit GameplayKit GameController; do echo "  $m"; build_mod "$m"; done

echo "→ game module"
mkdir -p "$B/src/game"; for f in "$GAMESRC"/*.swift; do strip "$f" > "$B/src/game/$(basename "$f")"; done
xcrun --toolchain swift swiftc "${EMB[@]}" -module-name AsteroidZ -c "$B/src/game"/*.swift -o "$B/mod/game.o"

echo "→ embedded runtime stubs (sb64 strtod / _initialize ctors / conformance)"
"$CLANG" --target=wasm32-wasi -Os -c "$FW/embedded/embedded-stubs.c" -o "$B/stubs.o"

echo "→ Box2D v3 (pure C) with -ffunction-sections (so --gc-sections strips unused joints/etc)"
mkdir -p "$B/box2d"; B2D="$FW/Sources/CBox2D"
for f in "$B2D"/src/*.c; do
  "$CLANG" --target=wasm32-unknown-wasip1 --sysroot="$SDK/WASI.sdk" -std=c17 -Os -DNDEBUG \
    -ffunction-sections -fdata-sections -I "$B2D/include" -c "$f" -o "$B/box2d/$(basename "$f").o"
done

echo "→ link (Swift + KitABI shim + Box2D v3 + embedded stdlib + WASI libc), --gc-sections"
SHIM="$ROOT/asteroidz-web/.build/wasm32-unknown-wasip1/release/KitABI.build/shim.c.o"
"$WASMLD" --no-entry --gc-sections --export=boot --export=frame --export=_initialize --export=memory --allow-undefined \
  -L "$SYSLIB" -o "$B/bossman-embedded.wasm" \
  "$B"/mod/*.o "$SHIM" "$B"/box2d/*.o "$B/stubs.o" "$UNI" -lc -lm \
  "$(find "$SDK" -name 'libclang_rt.builtins-wasm32.a' | head -1)"

wasm-opt -Oz --enable-bulk-memory --enable-nontrapping-float-to-int --enable-sign-ext \
  --enable-mutable-globals --enable-multivalue "$B/bossman-embedded.wasm" -o "$B/bossman-embedded-oz.wasm"

# Publish next to the normal web payload so CI (and the website deploy) can grab it.
OUT="$ROOT/asteroidz-web/web/asteroidz-embedded.wasm"
cp "$B/bossman-embedded-oz.wasm" "$OUT"
cp "$B/bossman-embedded.wasm" "$ROOT/asteroidz-web/web/asteroidz-embedded-named.wasm"

raw=$(stat -f%z "$OUT"); gz=$(gzip -c -9 "$OUT" | wc -c | tr -d ' ')
echo
echo "✓ Embedded AsteroidZ wasm: $raw bytes (-Oz), $gz gzip"
echo "  Normal full-game baseline: 5138028 raw / 1883322 gzip"
echo "  out: $OUT"
echo "  Boot: copy it as bossman.wasm next to runtime-embedded.js + assets, serve over HTTP."
