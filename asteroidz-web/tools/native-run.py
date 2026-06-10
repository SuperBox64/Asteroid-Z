# Run the AsteroidZ wasm under wasmtime (WASI Preview 1) - no browser, no JS,
# no webview. The web runtime's env.* surface is auto-stubbed from the
# module's import table; Swift print() reaches stdout via WASI fd_write.
#   python3 tools/native-run.py <wasm> [seconds]
import sys
from wasmtime import Store, Module, Linker, Engine, WasiConfig, FuncType, ValType

wasm = sys.argv[1] if len(sys.argv) > 1 else "web/asteroidz.wasm"
seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0

engine = Engine()
store = Store(engine)
wasi = WasiConfig()
wasi.inherit_stdout()
wasi.inherit_stderr()
store.set_wasi(wasi)

module = Module.from_file(engine, wasm)
linker = Linker(engine)
linker.define_wasi()

calls = {"gfx": 0}
for imp in module.imports:
    if imp.module != "env":
        continue
    ft = imp.type
    name = imp.name
    def make(name, ft):
        zeros = [0] * len(ft.results)
        def stub(*args):
            if name.startswith("gfx_"):
                calls["gfx"] += 1
            if len(zeros) == 0:
                return None
            return zeros[0] if len(zeros) == 1 else zeros
        return stub
    linker.define_func("env", name, ft, make(name, ft))

instance = linker.instantiate(store, module)
exports = instance.exports(store)
exports["_initialize"](store)
exports["boot"](store)
frames = round(seconds * 60)
for _ in range(frames):
    exports["frame"](store, 16.67)

print(f"\n--- wasmtime run complete: {frames} frames ({seconds:g}s), "
      f"{calls['gfx']:,} draw calls, zero JavaScript involved ---")
