#!/bin/bash
# AsteroidZ direct-native build: a thin wrapper over the framework's
# build-native-game.sh. Sounds bake into the binary - single file, no wasm.
set -euo pipefail
cd "$(dirname "$0")"
GAME_SRC="$(pwd)/game-src" 
rm -rf game-src && mkdir game-src
ln -s "$(cd ../asteroidz-web/Sources/AsteroidZ && pwd)/GameScene.swift" game-src/GameScene.swift
GAME_SRC="$GAME_SRC" \
GAME_MAIN="$(pwd)/main.swift" \
ASSETS_DIR="$(cd ../asteroidz-web/web/assets/sfx && pwd)" \
OUT="$(pwd)/asteroidz-direct" \
  ../../superbox64-spritekit/native/build-native-game.sh
rm -rf game-src
