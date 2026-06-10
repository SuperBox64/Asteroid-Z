// Run the AsteroidZ wasm natively under Node's WASI - no browser, no webview,
// no canvas. Every env.* host function the web runtime provides is auto-
// stubbed from the module's own import table; Swift print() reaches stdout
// through WASI fd_write, so game logs appear directly in the terminal.
//   node tools/native-run.js <wasm> [seconds]
const { readFileSync } = require('node:fs');
const { WASI } = require('node:wasi');

const wasmPath = process.argv[2] || 'web/asteroidz.wasm';
const seconds = Number(process.argv[3] || 5);

(async () => {
  const bytes = readFileSync(wasmPath);
  const module = await WebAssembly.compile(bytes);

  const wasi = new WASI({ version: 'preview1', args: [], env: {} });

  // Auto-stub the web runtime's host surface: void for most, 0 for handles.
  const env = {};
  let gfxCalls = 0;
  for (const imp of WebAssembly.Module.imports(module)) {
    if (imp.module !== 'env' || imp.kind !== 'function') continue;
    const name = imp.name;
    env[name] = name.startsWith('gfx_') ? (() => { gfxCalls++; return 0; })
                                        : (() => 0);
  }

  const instance = await WebAssembly.instantiate(module, {
    wasi_snapshot_preview1: wasi.wasiImport,
    env,
  });
  wasi.initialize(instance);

  instance.exports.boot();
  const frames = Math.round(seconds * 60);
  for (let i = 0; i < frames; i++) instance.exports.frame(16.67);

  console.log(`\n--- native WASI run complete: ${frames} frames (${seconds}s of game time), ` +
              `${gfxCalls.toLocaleString()} draw calls issued, no browser involved ---`);
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
