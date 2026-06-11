#!/bin/bash
# Android APK: SDL3's official android-project template (SDLActivity + gradle)
# around libmain.so cross-compiled from our Swift sources with the Swift
# Android SDK. Runs on ubuntu CI with ANDROID_HOME/ANDROID_NDK provided by
# the runner image.
set -euo pipefail
cd "$(dirname "$0")/.."
FW="${FW:-$(cd ../../superbox64-spritekit && pwd)}"
SDLVER="${SDL_VER:-3.4.10}"
API=28
TRIPLE=aarch64-unknown-linux-android$API
B="$(mktemp -d)"; trap 'rm -rf "$B"' EXIT
OUT="$PWD/release/out"; mkdir -p "$OUT"

git clone --depth 1 --branch "release-$SDLVER" https://github.com/libsdl-org/SDL "$B/SDL"

# the template project: SDLActivity java + gradle + SDL as a submodule build
cp -r "$B/SDL/android-project" "$B/app"
ln -s "$B/SDL" "$B/app/app/jni/SDL"
sed -i 's/org.libsdl.app/com.superbox64.asteroidz/' "$B/app/app/build.gradle" || true

# our libmain.so: game + framework + backend + box2d, Swift Android SDK
mkdir -p "$B/mod" "$B/box2d" "$B/src/game" "$B/CSDL3"
printf '#include <SDL3/SDL.h>\n' > "$B/CSDL3/shim.h"
cat > "$B/CSDL3/module.modulemap" <<MM
module CSDL3 {
    header "shim.h"
    export *
}
MM
NDK_CC="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
for c in "$FW"/Sources/CBox2D/src/*.c; do
  "$NDK_CC" --target=$TRIPLE -c -O2 -DNDEBUG -fPIC \
    -I "$FW/Sources/CBox2D/include" -I "$FW/Sources/CBox2D/src" \
    "$c" -o "$B/box2d/$(basename "$c" .c).o"
done

SWIFT_FLAGS=(-O -wmo -parse-as-library
  -target $TRIPLE --swift-sdk $TRIPLE
  -Xcc -fmodule-map-file="$FW/Sources/KitABI/include/module.modulemap"
  -Xcc -fmodule-map-file="$FW/Sources/CBox2D/include/module.modulemap"
  -Xcc -fmodule-map-file="$B/CSDL3/module.modulemap"
  -Xcc -I"$B/SDL/include"
  -I "$FW/Sources/KitABI/include" -I "$FW/Sources/CBox2D/include" -I "$B/CSDL3")

SOURCES=()
for m in SpriteKit AppKit GameplayKit GameController; do
  for f in "$FW/Sources/$m"/*.swift; do
    dst="$B/src/game/$m-$(basename "$f")"
    sed -e 's/@MainActor//g' -e 's/@preconcurrency//g' "$f" > "$dst"
    SOURCES+=("$dst")
  done
done
sed -e 's/@MainActor//g' "../asteroidz-web/Sources/AsteroidZ/GameScene.swift" > "$B/src/game/GameScene.swift"
sed -e 's/@MainActor//g' "$FW/native/sdl3-backend.swift" > "$B/src/game/backend.swift"
sed -e 's/@MainActor//g' main.swift > "$B/src/game/main.swift"
SOURCES+=("$B/src/game/GameScene.swift" "$B/src/game/backend.swift" "$B/src/game/main.swift")

python3 release/gen-stubs.py "$FW/Sources/KitABI/include/KitABI.h" "$B/stubs.c"
python3 release/gen-assets.py "../asteroidz-web/web/assets/sfx" "$B/assets.c"
"$NDK_CC" --target=$TRIPLE -c -O2 -fPIC -I "$FW/Sources/KitABI/include" "$B/stubs.c" -o "$B/stubs.o"
"$NDK_CC" --target=$TRIPLE -c -O2 -fPIC -I "$FW/Sources/KitABI/include" "$FW/Sources/KitABI/shim.c" -o "$B/shim.o"
"$NDK_CC" --target=$TRIPLE -c -O2 -fPIC "$B/assets.c" -o "$B/assets.o"

swiftc "${SWIFT_FLAGS[@]}" -emit-library -module-name GameNative \
  "${SOURCES[@]}" \
  -Xlinker "$B/stubs.o" -Xlinker "$B/shim.o" -Xlinker "$B/assets.o" \
  $(for o in "$B"/box2d/*.o; do printf -- "-Xlinker %s " "$o"; done) \
  -o "$B/libmain-pre.so"

# the template loads libmain.so + the SDL3 lib built by its own gradle/cmake
JNIDIR="$B/app/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNIDIR"
cp "$B/libmain-pre.so" "$JNIDIR/libmain.so"
# Swift Android runtime libs ride along
SDKLIBS="$(swift sdk configure $TRIPLE --show-configuration 2>/dev/null | grep -o '/.*swift.*/usr/lib/swift-aarch64' | head -1 || true)"
[ -n "$SDKLIBS" ] && cp "$SDKLIBS"/android/*.so "$JNIDIR/" 2>/dev/null || true

( cd "$B/app" && ./gradlew assembleRelease )
cp "$B/app/app/build/outputs/apk/release/"*.apk "$OUT/AsteroidZ.apk"
echo "✓ $OUT/AsteroidZ.apk (unsigned unless CI signs)"
