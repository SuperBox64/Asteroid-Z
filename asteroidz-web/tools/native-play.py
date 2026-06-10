# Playable NATIVE host for the AsteroidZ wasm: wasmtime (WASI p1) + pygame.
# No browser, no webview, no JavaScript. The same .wasm that runs on the
# website renders into an SDL window; KitABI's env.* surface is implemented
# on pygame (matrix stack, polygon strokes, mixer audio, event queue).
#
#   python3 tools/native-play.py [wasm] [--selftest seconds]
#
# Controls match the web build: arrows/WASD + Space, C = coin/start.
import json
import math
import os
import struct
import sys

os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
import pygame
from wasmtime import Engine, Linker, Module, Store, WasiConfig

WASM = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "web/asteroidz.wasm"
SELFTEST = 0.0
if "--selftest" in sys.argv:
    SELFTEST = float(sys.argv[sys.argv.index("--selftest") + 1])
    os.environ["SDL_VIDEODRIVER"] = "dummy"
    os.environ["SDL_AUDIODRIVER"] = "dummy"

LOGICAL_W, LOGICAL_H = 1920, 1080
WINDOW_W, WINDOW_H = 1280, 720
STORE_PATH = os.path.join(os.path.dirname(__file__), ".native-store.json")

# SFML key codes (the ABI's event vocabulary; the framework maps them on)
SF_KEYS = {
    pygame.K_LEFT: 71, pygame.K_RIGHT: 72, pygame.K_UP: 73, pygame.K_DOWN: 74,
    pygame.K_SPACE: 57, pygame.K_ESCAPE: 36, pygame.K_RETURN: 58,
    pygame.K_BACKSPACE: 59, pygame.K_TAB: 60,
    pygame.K_a: 0, pygame.K_b: 1, pygame.K_c: 2, pygame.K_d: 3, pygame.K_e: 4,
    pygame.K_f: 5, pygame.K_g: 6, pygame.K_h: 7, pygame.K_i: 8, pygame.K_j: 9,
    pygame.K_k: 10, pygame.K_l: 11, pygame.K_m: 12, pygame.K_n: 13, pygame.K_o: 14,
    pygame.K_p: 15, pygame.K_q: 16, pygame.K_r: 17, pygame.K_s: 18, pygame.K_t: 19,
    pygame.K_u: 20, pygame.K_v: 21, pygame.K_w: 22, pygame.K_x: 23, pygame.K_y: 24,
    pygame.K_z: 25,
    pygame.K_0: 26, pygame.K_1: 27, pygame.K_2: 28, pygame.K_3: 29, pygame.K_4: 30,
    pygame.K_5: 31, pygame.K_6: 32, pygame.K_7: 33, pygame.K_8: 34, pygame.K_9: 35,
}


class Matrix:
    """Canvas2D-compatible affine stack: [a b c d e f] maps (x,y) ->
    (a*x + c*y + e, b*x + d*y + f)."""

    def __init__(self):
        self.m = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
        self.stack = []

    def save(self):
        self.stack.append(self.m[:])

    def restore(self):
        if self.stack:
            self.m = self.stack.pop()

    def _mul(self, n):
        a, b, c, d, e, f = self.m
        na, nb, nc, nd, ne, nf = n
        self.m = [
            a * na + c * nb, b * na + d * nb,
            a * nc + c * nd, b * nc + d * nd,
            a * ne + c * nf + e, b * ne + d * nf + f,
        ]

    def translate(self, x, y):
        self._mul([1, 0, 0, 1, x, y])

    def rotate_deg(self, deg):
        r = math.radians(deg)
        self._mul([math.cos(r), math.sin(r), -math.sin(r), math.cos(r), 0, 0])

    def scale(self, x, y):
        self._mul([x, 0, 0, y, 0, 0])

    def apply(self, x, y):
        a, b, c, d, e, f = self.m
        return (a * x + c * y + e, b * x + d * y + f)

    def length_scale(self):
        a, b, c, d = self.m[:4]
        return (math.hypot(a, b) + math.hypot(c, d)) / 2


class Host:
    def __init__(self, surface):
        self.surface = surface
        self.mat = Matrix()
        self.alpha = 1.0
        self.events = []
        self.sounds = {}
        self.sound_names = {}
        self.next_sound = 1
        self.store = {}
        if os.path.exists(STORE_PATH):
            try:
                self.store = json.load(open(STORE_PATH))
            except Exception:
                self.store = {}
        self.memory = None
        self.store_fn = None
        self.gfx_calls = 0

    # --- wasm memory helpers -------------------------------------------------
    def floats(self, ptr, n):
        raw = self.memory.read(self.store_fn, ptr, ptr + n * 4)
        return struct.unpack(f"<{n}f", raw)

    def cstr(self, ptr, length):
        return self.memory.read(self.store_fn, ptr, ptr + length).decode("utf-8", "replace")

    def write_i32(self, ptr, v):
        self.memory.write(self.store_fn, struct.pack("<i", v), ptr)

    # --- color: scale toward black by effective alpha (exact on black bg) ----
    def color(self, rgba):
        a = ((rgba & 0xFF) / 255.0) * self.alpha
        return (
            int(((rgba >> 24) & 0xFF) * a),
            int(((rgba >> 16) & 0xFF) * a),
            int(((rgba >> 8) & 0xFF) * a),
        )

    def pts(self, ptr, n):
        f = self.floats(ptr, n * 2)
        return [self.mat.apply(f[i * 2], f[i * 2 + 1]) for i in range(n)]

    # --- env.* ---------------------------------------------------------------
    def gfx_clear(self, rgba):
        self.mat = Matrix()
        self.alpha = 1.0
        self.surface.fill(self.color(rgba))

    def gfx_stroke_poly(self, ptr, n, closed, thickness, rgba):
        self.gfx_calls += 1
        if n < 2:
            return
        w = max(1, round(thickness * self.mat.length_scale()))
        pygame.draw.lines(self.surface, self.color(rgba), bool(closed), self.pts(ptr, n), w)

    def gfx_fill_poly(self, ptr, n, rgba):
        self.gfx_calls += 1
        if n < 3:
            return
        pygame.draw.polygon(self.surface, self.color(rgba), self.pts(ptr, n))

    def gfx_fill_circle(self, cx, cy, r, rgba):
        self.gfx_calls += 1
        x, y = self.mat.apply(cx, cy)
        pygame.draw.circle(self.surface, self.color(rgba), (x, y), max(1, r * self.mat.length_scale()))

    def gfx_stroke_circle(self, cx, cy, r, thickness, rgba):
        self.gfx_calls += 1
        x, y = self.mat.apply(cx, cy)
        s = self.mat.length_scale()
        pygame.draw.circle(self.surface, self.color(rgba), (x, y), max(1, r * s),
                           max(1, round(thickness * s)))

    def gfx_fill_rect(self, x, y, w, h, rgba):
        self.gfx_fill_poly_pts([(x, y), (x + w, y), (x + w, y + h), (x, y + h)], rgba)

    def gfx_stroke_rect(self, x, y, w, h, thickness, rgba):
        self.gfx_calls += 1
        pts = [self.mat.apply(*p) for p in [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]]
        wpx = max(1, round(thickness * self.mat.length_scale()))
        pygame.draw.lines(self.surface, self.color(rgba), True, pts, wpx)

    def gfx_fill_poly_pts(self, pts, rgba):
        self.gfx_calls += 1
        pygame.draw.polygon(self.surface, self.color(rgba), [self.mat.apply(*p) for p in pts])

    def evt_poll(self, t, a, b, c, d):
        if not self.events:
            return 0
        e = self.events.pop(0)
        for ptr, v in zip((t, a, b, c, d), e):
            self.write_i32(ptr, int(v))
        return 1

    def snd_by_name(self, ptr, length):
        name = os.path.basename(self.cstr(ptr, length))
        if name in self.sound_names:
            return self.sound_names[name]
        path = os.path.join(os.path.dirname(__file__), "..", "web", "assets", "sfx", name)
        sid = self.next_sound
        self.next_sound += 1
        try:
            self.sounds[sid] = pygame.mixer.Sound(path)
        except Exception:
            self.sounds[sid] = None
        self.sound_names[name] = sid
        return sid

    def snd_play(self, sid, volume, loop):
        s = self.sounds.get(sid)
        if s is None:
            return 0
        s.set_volume(volume)
        s.play(loops=-1 if loop else 0)
        return sid

    def store_get(self, kptr, klen, bufptr, cap):
        key = self.cstr(kptr, klen)
        val = self.store.get(key)
        if val is None:
            return -1
        data = val.encode()[:cap]
        self.memory.write(self.store_fn, data, bufptr)
        return len(data)

    def store_set(self, kptr, klen, vptr, vlen):
        self.store[self.cstr(kptr, klen)] = self.cstr(vptr, vlen)
        try:
            json.dump(self.store, open(STORE_PATH, "w"))
        except Exception:
            pass


def main():
    pygame.init()
    try:
        pygame.mixer.init()
    except Exception:
        pass
    window = pygame.display.set_mode((WINDOW_W, WINDOW_H))
    pygame.display.set_caption("AsteroidZ — native (wasmtime + SDL, no webview)")
    surface = pygame.Surface((LOGICAL_W, LOGICAL_H))
    host = Host(surface)

    engine = Engine()
    store = Store(engine)
    wasi = WasiConfig()
    wasi.inherit_stdout()
    wasi.inherit_stderr()
    store.set_wasi(wasi)
    host.store_fn = store

    module = Module.from_file(engine, WASM)
    linker = Linker(engine)
    linker.define_wasi()

    impl = {
        "gfx_clear": host.gfx_clear,
        "gfx_save": lambda: host.mat.save(),
        "gfx_restore": lambda: host.mat.restore(),
        "gfx_translate": lambda x, y: host.mat.translate(x, y),
        "gfx_rotate": lambda deg: host.mat.rotate_deg(deg),
        "gfx_scale": lambda x, y: host.mat.scale(x, y),
        "gfx_set_alpha": lambda a: setattr(host, "alpha", a),
        "gfx_stroke_poly": host.gfx_stroke_poly,
        "gfx_fill_poly": host.gfx_fill_poly,
        "gfx_fill_circle": host.gfx_fill_circle,
        "gfx_stroke_circle": host.gfx_stroke_circle,
        "gfx_fill_rect": host.gfx_fill_rect,
        "gfx_stroke_rect": host.gfx_stroke_rect,
        "evt_poll": host.evt_poll,
        "snd_by_name": host.snd_by_name,
        "snd_play": host.snd_play,
        "store_get": host.store_get,
        "store_set": host.store_set,
    }
    stubbed = []
    for imp in module.imports:
        if imp.module != "env":
            continue
        ft, name = imp.type, imp.name
        if name in impl:
            linker.define_func("env", name, ft, impl[name])
        else:
            zeros = [0] * len(ft.results)
            def make(z):
                return lambda *a: (None if not z else (z[0] if len(z) == 1 else z))
            linker.define_func("env", name, ft, make(zeros))
            stubbed.append(name)

    instance = linker.instantiate(store, module)
    ex = instance.exports(store)
    host.memory = ex["memory"]
    ex["_initialize"](store)
    ex["boot"](store)

    clock = pygame.time.Clock()
    running = True
    elapsed = 0.0
    frames = 0
    while running:
        for e in pygame.event.get():
            if e.type == pygame.QUIT:
                running = False
            elif e.type in (pygame.KEYDOWN, pygame.KEYUP):
                sf = SF_KEYS.get(e.key)
                if sf is not None:
                    t = 5 if e.type == pygame.KEYDOWN else 6
                    shift = 1 if e.mod & pygame.KMOD_SHIFT else 0
                    host.events.append((t, sf, shift, 0, 0))
            elif e.type in (pygame.MOUSEBUTTONDOWN, pygame.MOUSEBUTTONUP):
                t = 9 if e.type == pygame.MOUSEBUTTONDOWN else 10
                lx = e.pos[0] * LOGICAL_W / WINDOW_W
                ly = e.pos[1] * LOGICAL_H / WINDOW_H
                host.events.append((t, 0, lx, ly, 0))
            elif e.type == pygame.MOUSEMOTION:
                lx = e.pos[0] * LOGICAL_W / WINDOW_W
                ly = e.pos[1] * LOGICAL_H / WINDOW_H
                host.events.append((11, lx, ly, 0, 0))

        dt = clock.tick(60)
        ex["frame"](store, float(dt))
        pygame.transform.smoothscale(surface, (WINDOW_W, WINDOW_H), window)
        pygame.display.flip()

        frames += 1
        elapsed += dt / 1000.0
        if SELFTEST:
            if abs(elapsed - 1.0) < 0.02:
                host.events.append((5, 57, 0, 0, 0))   # Space: start the game
                host.events.append((6, 57, 0, 0, 0))
            if abs(elapsed - 2.0) < 0.02:
                host.events.append((5, 73, 0, 0, 0))   # hold thrust
            if elapsed >= SELFTEST:
                out = os.path.join(os.path.dirname(__file__), "native-play.png")
                pygame.image.save(surface, out)
                print(f"selftest: {frames} frames, {host.gfx_calls:,} draws, "
                      f"{len(stubbed)} env fns stubbed, screenshot -> {out}")
                running = False

    pygame.quit()


if __name__ == "__main__":
    main()
