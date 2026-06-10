# AsteroidZ native host — Embedded Swift end to end

No browser. No webview. No JavaScript. **No Swift stdlib on either side.**

```
┌────────────────────────────┐     ┌──────────────────────────────┐
│ asteroidz-embedded.wasm    │     │ asteroidz-native (188 KB)    │
│ Embedded Swift game        │ ──► │ Embedded Swift host          │
│ (507 KB, same file the     │     │ SDL3 + wasmtime via C        │
│  website serves)           │     │ interop                      │
└────────────────────────────┘     └──────────────────────────────┘
```

The game wasm is the identical artifact the website serves; the web build is
untouched. The host implements KitABI's `env.*` surface on SDL3: a Canvas2D-
compatible matrix stack, thick polylines via `SDL_RenderGeometry`, the SFML
event vocabulary from SDL events, WAV voices on SDL audio streams, and the
persistence store as a tsv file. wasmtime's C API runs the module with WASI
Preview 1 (Swift `print` lands on stdout).

## Build & run

```sh
brew install sdl3 wasmtime
./build.sh
./asteroidz-native                       # window: arrows/WASD + Space, C = coin
ASTEROIDZ_SELFTEST=4 ./asteroidz-native  # auto-play 4s, screenshot, exit
ASTEROIDZ_WASM=path.wasm ./asteroidz-native
```

Controls, persistence keys, and behavior match the web build exactly — it is
the same cartridge in a different console.
