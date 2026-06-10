# AsteroidZ headless tests

puppeteer-core drives the system Chrome against the wasm build with real
trusted input. Serve the build first:

```sh
cd asteroidz-web && ./build.sh release
python3 -m http.server 9100 --directory web
npm install puppeteer-core   # once, in this directory
```

| Script | What it proves |
|---|---|
| `drive.js <url> <prefix>` | boots, starts with Space, plays with arrows + fire (shared with Boss-Man) |
| `controls.js <url> <out> touch` | first touch auto-enables stick-right; multi-touch stick + fire |
| `controls.js <url> <out> mouse` | mouse drives the same widgets (desktop testing) |
| `controls.js <url> <out> button` | the retro controls-cycle button on the launch screen |
| `rotate-check.js <url> <out>` | left rotate tilts the nose counter-clockwise (macOS parity) |

The Boss-Man repo's `tests/headless/` has the measurement tooling
(`measure-boss.py`-style pixel analysis) if a test needs quantified output.
