#!/bin/bash
# Permutation 3: NO WASM. Game + SuperBox64 framework + SDL3 backend + Box2D
# v3 compile to ONE native arm64 binary. Embedded Swift end to end.
set -euo pipefail
cd "$(dirname "$0")"
FW="$(cd ../../superbox64-spritekit && pwd)"
TC="$(dirname "$(dirname "$(TOOLCHAINS=${SWIFT_TOOLCHAIN:-org.swift.6.3.2-release} xcrun --toolchain swift -f swiftc)")")"
B="$(mktemp -d)"
trap 'rm -rf "$B"' EXIT

EMB=(-enable-experimental-feature Embedded -wmo -Osize -parse-as-library
     -target arm64-apple-macos14
     -Xcc -fmodule-map-file="$FW/Sources/KitABI/include/module.modulemap"
     -Xcc -fmodule-map-file="$FW/Sources/CBox2D/include/module.modulemap"
     -Xcc -fmodule-map-file="$PWD/CSDL3/module.modulemap"
     -Xcc -I/opt/homebrew/include
     -I "$FW/Sources/KitABI/include" -I "$FW/Sources/CBox2D/include" -I "$PWD/CSDL3"
     -I "$B/mod")

export TOOLCHAINS="${SWIFT_TOOLCHAIN:-org.swift.6.3.2-release}"
mkdir -p "$B/mod" "$B/box2d" "$B/src"

echo "→ Box2D v3 (pure C, native)"
for c in "$FW"/Sources/CBox2D/src/*.c; do
  clang -c -O2 -DNDEBUG -ffunction-sections -I "$FW/Sources/CBox2D/include" -I "$FW/Sources/CBox2D/src" \
    -target arm64-apple-macos14 "$c" -o "$B/box2d/$(basename "$c" .c).o"
done

echo "→ framework modules (dependency order)"
build_mod() {
  local m="$1"
  mkdir -p "$B/src/$m"
  for f in "$FW/Sources/$m"/*.swift; do
    sed -e 's/@MainActor//g' -e 's/@preconcurrency//g' "$f" > "$B/src/$m/$(basename "$f")"
  done
  xcrun --toolchain swift swiftc "${EMB[@]}" -module-name "$m" \
    -emit-module -emit-module-path "$B/mod/$m.swiftmodule" \
    -c "$B/src/$m"/*.swift -o "$B/mod/$m.o"
}
for m in SpriteKit AppKit GameplayKit GameController; do echo "  $m"; build_mod "$m"; done

echo "→ game + backend + main (one module)"
mkdir -p "$B/src/game"
sed -e 's/@MainActor//g' "../asteroidz-web/Sources/AsteroidZ/GameScene.swift" > "$B/src/game/GameScene.swift"
cp backend.swift main.swift "$B/src/game/"
xcrun --toolchain swift swiftc "${EMB[@]}" -module-name AsteroidZDirect \
  -c "$B/src/game"/*.swift -o "$B/mod/game.o"

echo "→ stubs (Embedded strtod + untouched KitABI surface, generated from the header)"
python3 - "$FW/Sources/KitABI/include/KitABI.h" "$B/stubs.c" <<'PYEOF'
import re, sys
hdr, out = sys.argv[1], sys.argv[2]
text = open(hdr).read()
protos = re.findall(r"WABI\s+([^;]+);", text)
implemented = {
    "js_log", "gfx_clear", "gfx_save", "gfx_restore", "gfx_translate",
    "gfx_rotate", "gfx_scale", "gfx_set_alpha", "gfx_stroke_poly",
    "gfx_fill_poly", "gfx_fill_circle", "gfx_stroke_circle", "gfx_fill_rect",
    "gfx_stroke_rect", "evt_poll", "snd_by_name", "snd_play", "store_get",
    "store_set", "gp_connected",
}
lines = ['#include "KitABI.h"', "#include <stdlib.h>",
         "double _swift_stdlib_strtod_clocale(const char *str, char **end) { return strtod(str, end); }"]
for p in protos:
    p = " ".join(p.split())
    m = re.match(r"([A-Za-z0-9_*\s]+?)\s*\b([a-z_0-9]+)\s*\(", p)
    if not m:
        continue
    ret, name = m.group(1).strip(), m.group(2)
    if name in implemented:
        continue
    body = "{}" if ret == "void" else "{ return 0; }"
    lines.append(p + " " + body)
open(out, "w").write("\n".join(lines) + "\n")
print(f"  {len(lines) - 3} stubbed")
PYEOF
clang -c -O2 -I "$FW/Sources/KitABI/include" -target arm64-apple-macos14 "$B/stubs.c" -o "$B/mod/stubs.o"
clang -c -O2 -I "$FW/Sources/KitABI/include" -target arm64-apple-macos14 "$FW/Sources/KitABI/shim.c" -o "$B/mod/shim.o"

echo "→ link (game + framework + Box2D + SDL3 backend, one binary)"
clang -target arm64-apple-macos14 -o asteroidz-direct \
  "$B"/mod/*.o "$B"/box2d/*.o \
  -L /opt/homebrew/lib -lSDL3 \
  "$TC/lib/swift/embedded/arm64-apple-macos/libswiftUnicodeDataTables.a" \
  -dead_strip

echo "✓ asteroidz-direct ($(stat -f%z asteroidz-direct) bytes) - no wasm, no wasmtime, no webview"
