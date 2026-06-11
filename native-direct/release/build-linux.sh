#!/bin/bash
# Linux release (runs on ubuntu CI or any Linux box with swiftly):
# Embedded Swift x86_64 binary + .deb. SDL3 built static, minimal subsystems.
set -euo pipefail
cd "$(dirname "$0")/.."
FW="${FW:-$(cd ../../SuperBox64Kit && pwd)}"
VER="${VERSION:-1.0.0}"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
TRIPLE="$( [ "$ARCH" = arm64 ] && echo aarch64-unknown-linux-gnu || echo x86_64-unknown-linux-gnu )"
B="$(mktemp -d)"; trap 'rm -rf "$B"' EXIT

# static minimal SDL3
if [ ! -f vendor-linux/libSDL3.a ]; then
  mkdir -p vendor-linux
  git clone --depth 1 --branch "release-${SDL_VER:-3.4.10}" https://github.com/libsdl-org/SDL "$B/SDL"
  cmake -S "$B/SDL" -B "$B/sdlbuild" -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF \
    -DSDL_CAMERA=OFF -DSDL_SENSOR=OFF -DSDL_HAPTIC=OFF -DSDL_GPU=OFF \
    -DSDL_VULKAN=OFF -DSDL_DIALOG=OFF -DSDL_POWER=OFF \
    -DSDL_JOYSTICK=OFF -DSDL_HIDAPI=OFF >/dev/null
  cmake --build "$B/sdlbuild" -j >/dev/null
  cp "$B/sdlbuild/libSDL3.a" vendor-linux/
  cp -r "$B/SDL/include/SDL3" vendor-linux/SDL3
fi

EMB=(-enable-experimental-feature Embedded -wmo -Osize -parse-as-library
     -target "$TRIPLE"
     -Xcc -fmodule-map-file="$FW/Sources/KitABI/include/module.modulemap"
     -Xcc -fmodule-map-file="$FW/Sources/CBox2D/include/module.modulemap"
     -Xcc -fmodule-map-file="$PWD/CSDL3-linux/module.modulemap"
     -Xcc -I"$PWD/vendor-linux"
     -I "$FW/Sources/KitABI/include" -I "$FW/Sources/CBox2D/include" -I "$PWD/CSDL3-linux"
     -I "$B/mod")
mkdir -p "$B/mod" "$B/box2d" "$B/src" CSDL3-linux
cat > CSDL3-linux/module.modulemap <<MM
module CSDL3 {
    header "shim.h"
    link "SDL3"
    export *
}
MM
printf '#include <SDL3/SDL.h>\n' > CSDL3-linux/shim.h

for c in "$FW"/Sources/CBox2D/src/*.c; do
  clang -c -O2 -DNDEBUG -ffunction-sections -I "$FW/Sources/CBox2D/include" -I "$FW/Sources/CBox2D/src" \
    "$c" -o "$B/box2d/$(basename "$c" .c).o"
done

build_mod() {
  local m="$1"; mkdir -p "$B/src/$m"
  for f in "$FW/Sources/$m"/*.swift; do
    sed -e 's/@MainActor//g' -e 's/@preconcurrency//g' "$f" > "$B/src/$m/$(basename "$f")"
  done
  swiftc "${EMB[@]}" -module-name "$m" \
    -emit-module -emit-module-path "$B/mod/$m.swiftmodule" \
    -c "$B/src/$m"/*.swift -o "$B/mod/$m.o"
}
for m in SpriteKit AppKit GameplayKit GameController; do build_mod "$m"; done

mkdir -p "$B/src/game"
sed -e 's/@MainActor//g' "../asteroidz-web/Sources/AsteroidZ/GameScene.swift" > "$B/src/game/GameScene.swift"
sed -e 's/@MainActor//g' "$FW/native/sdl3-backend.swift" > "$B/src/game/sdl3-backend.swift"
cp main.swift "$B/src/game/native-main.swift"
swiftc "${EMB[@]}" -module-name GameNative -c "$B/src/game"/*.swift -o "$B/mod/game.o"

python3 - "$FW/Sources/KitABI/include/KitABI.h" "$B/stubs.c" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
protos = re.findall(r"WABI\s+([^;]+);", text)
implemented = {
    "js_log","gfx_clear","gfx_save","gfx_restore","gfx_translate","gfx_rotate",
    "gfx_scale","gfx_set_alpha","gfx_set_blend","gfx_stroke_poly","gfx_fill_poly",
    "gfx_fill_circle","gfx_stroke_circle","gfx_fill_rect","gfx_stroke_rect",
    "evt_poll","snd_by_name","snd_play","snd_stop","snd_set_volume","snd_set_pan",
    "store_get","store_set","gp_connected",
}
lines = ['#include "KitABI.h"', "#include <stdlib.h>",
         "double _swift_stdlib_strtod_clocale(const char *s, char **e){ return strtod(s,e); }"]
for p in protos:
    p = " ".join(p.split())
    m = re.match(r"([A-Za-z0-9_*\s]+?)\s*\b([a-z_0-9]+)\s*\(", p)
    if not m or m.group(2) in implemented: continue
    lines.append(p + (" {}" if m.group(1).strip() == "void" else " { return 0; }"))
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
PYEOF
clang -c -O2 -I "$FW/Sources/KitABI/include" "$B/stubs.c" -o "$B/mod/stubs.o"
clang -c -O2 -I "$FW/Sources/KitABI/include" "$FW/Sources/KitABI/shim.c" -o "$B/mod/shim.o"

TC="$(dirname "$(dirname "$(command -v swiftc)")")"
ASSETS_DIR="$(cd ../asteroidz-web/web/assets/sfx && pwd)"
python3 - "$ASSETS_DIR" "$B/assets.c" <<'PYEOF'
import os, sys
src, out = sys.argv[1], sys.argv[2]
lines = ["#include <stdint.h>"]
entries = []
for i, name in enumerate(sorted(os.listdir(src))):
    if not name.endswith(".wav"): continue
    data = open(os.path.join(src, name), "rb").read()
    lines.append(f"static const unsigned char a{i}[] = {{{','.join(str(b) for b in data)}}};")
    entries.append((name, f"a{i}", len(data)))
lines.append("static const struct { const char *n; const unsigned char *d; uint32_t l; } tbl[] = {")
for n_, s_, l_ in entries: lines.append(f'    {{"{n_}", {s_}, {l_}}},')
lines.append("};")
lines.append("""const unsigned char *kit_asset_data(const char *name, uint32_t *len) {
    for (unsigned i = 0; i < sizeof(tbl)/sizeof(tbl[0]); i++) {
        const char *a = tbl[i].n, *b = name;
        while (*a && *a == *b) { a++; b++; }
        if (*a == *b) { *len = tbl[i].l; return tbl[i].d; }
    }
    *len = 0; return 0;
}""")
open(out, "w").write("\n".join(lines))
PYEOF
clang -c -O2 "$B/assets.c" -o "$B/mod/assets.o"

clang -o asteroidz-direct-linux \
  "$B"/mod/*.o "$B"/box2d/*.o \
  vendor-linux/libSDL3.a \
  "$TC/lib/swift/embedded/$TRIPLE/libswiftUnicodeDataTables.a" \
  -lm -lpthread -ldl -Wl,--gc-sections
strip asteroidz-direct-linux
echo "✓ asteroidz-direct-linux ($(stat -c%s asteroidz-direct-linux) bytes)"

# .deb
D="$B/deb"
mkdir -p "$D/DEBIAN" "$D/usr/games" "$D/usr/share/applications"
cp asteroidz-direct-linux "$D/usr/games/asteroidz"
cat > "$D/DEBIAN/control" <<CTRL
Package: asteroidz
Version: $VER
Architecture: $ARCH
Maintainer: Todd Bruss <todd@starplayrx.com>
Description: AsteroidZ - retro vector arcade (Embedded Swift, SDL3, no webview)
CTRL
cat > "$D/usr/share/applications/asteroidz.desktop" <<DESK
[Desktop Entry]
Name=AsteroidZ
Exec=/usr/games/asteroidz
Type=Application
Categories=Game;
DESK
dpkg-deb --build "$D" "asteroidz_${VER}_${ARCH}.deb"
echo "✓ asteroidz_${VER}_${ARCH}.deb"
