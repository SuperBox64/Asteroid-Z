# AsteroidZ native host — Embedded Swift end to end

The canonical native backend sources live in
`asteroidz-web/Packages/SuperBox64Kit/native/`:

- `wasmtime-host.swift` — the wasmtime cartridge host (permutation 2)
- `sdl3-backend.swift` — the direct SDL3 backend (permutation 3)
- `CSDL3/` and `CWasmtime/` — cross-platform module maps for SDL3 and wasmtime
- `build-wasmtime-host.sh` — builds the wasmtime host
- `build-native-game.sh` — builds the direct native binary

The `build.sh` in this directory is a thin wrapper that delegates to the
canonical build script. See `asteroidz-web/Packages/SuperBox64Kit/native/README.md`
for full documentation.

```sh
./build.sh                       # delegates to build-wasmtime-host.sh
./asteroidz-wasmtime-host        # loads asteroidz-embedded.wasm via wasmtime
```