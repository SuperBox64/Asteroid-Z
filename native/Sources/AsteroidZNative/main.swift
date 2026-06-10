// AsteroidZ native host - EMBEDDED Swift on BOTH sides of the cartridge slot:
// the game wasm is Embedded Swift (no stdlib) and this host is compiled with
// the same Embedded mode (no Swift stdlib, no Foundation). All platform work
// goes through C interop: SDL3 for window/render/input/audio/files/math and
// the wasmtime C API to run the wasm. No browser, no webview, no JavaScript.
//
//   ./build.sh && ./asteroidz-native            (window, arrows/WASD + Space)
//   ASTEROIDZ_SELFTEST=4 ./asteroidz-native     (auto-play, screenshot, exit)
import CSDL3
import CWasmtime

let LOGICAL_W: Float = 1920
let LOGICAL_H: Float = 1080

// MARK: - Canvas2D-compatible affine matrix

struct Mat {
    var a: Float = 1, b: Float = 0, c: Float = 0, d: Float = 1, e: Float = 0, f: Float = 0

    mutating func mul(_ n: Mat) {
        self = Mat(
            a: a * n.a + c * n.b, b: b * n.a + d * n.b,
            c: a * n.c + c * n.d, d: b * n.c + d * n.d,
            e: a * n.e + c * n.f + e, f: b * n.e + d * n.f + f
        )
    }

    func apply(_ x: Float, _ y: Float) -> SDL_FPoint {
        SDL_FPoint(x: a * x + c * y + e, y: b * x + d * y + f)
    }

    var lengthScale: Float {
        (SDL_sqrtf(a * a + b * b) + SDL_sqrtf(c * c + d * d)) / 2
    }
}

// MARK: - Host state

final class Host {
    var renderer: OpaquePointer? = nil
    var mat = Mat()
    var stack: [Mat] = []
    var alpha: Float = 1
    var events: [(Int32, Int32, Int32, Int32, Int32)] = []
    var memoryBase: UnsafeMutablePointer<UInt8>? = nil
    var soundSpecs: [SDL_AudioSpec] = [SDL_AudioSpec()]
    var soundBufs: [UnsafeMutablePointer<UInt8>?] = [nil]
    var soundLens: [UInt32] = [0]
    var soundNames: [String: Int32] = [:]
    var streams: [OpaquePointer] = []
    var storeKeys: [String] = []
    var storeVals: [String] = []
    var assetDir = ""
    var storePath = ""
    var drawCalls = 0

    func floats(_ ptr: Int32, _ n: Int) -> [Float] {
        let p = UnsafeRawPointer(memoryBase! + Int(ptr))
        var out = [Float]()
        out.reserveCapacity(n)
        for i in 0..<n { out.append(p.loadUnaligned(fromByteOffset: i * 4, as: Float.self)) }
        return out
    }

    func str(_ ptr: Int32, _ len: Int32) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Int(len) + 1)
        for i in 0..<Int(len) { bytes.append(memoryBase![Int(ptr) + i]) }
        bytes.append(0)
        return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    func writeI32(_ ptr: Int32, _ v: Int32) {
        UnsafeMutableRawPointer(memoryBase! + Int(ptr)).storeBytes(of: v, toByteOffset: 0, as: Int32.self)
    }

    func fcolor(_ rgba: UInt32) -> SDL_FColor {
        SDL_FColor(
            r: Float((rgba >> 24) & 0xFF) / 255,
            g: Float((rgba >> 16) & 0xFF) / 255,
            b: Float((rgba >> 8) & 0xFF) / 255,
            a: Float(rgba & 0xFF) / 255 * alpha
        )
    }

    // Thick polyline: one quad per segment via RenderGeometry.
    func strokePoly(_ pts: [SDL_FPoint], closed: Bool, thickness: Float, rgba: UInt32) {
        drawCalls += 1
        if pts.count < 2 { return }
        let color = fcolor(rgba)
        let w = max(1, thickness * mat.lengthScale) / 2
        var verts = [SDL_Vertex]()
        var idx = [Int32]()
        let segs = closed ? pts.count : pts.count - 1
        for i in 0..<segs {
            let p1 = pts[i]
            let p2 = pts[(i + 1) % pts.count]
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let len = max(SDL_sqrtf(dx * dx + dy * dy), 0.0001)
            let nx = -dy / len * w
            let ny = dx / len * w
            let base = Int32(verts.count)
            verts.append(SDL_Vertex(position: SDL_FPoint(x: p1.x + nx, y: p1.y + ny), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            verts.append(SDL_Vertex(position: SDL_FPoint(x: p2.x + nx, y: p2.y + ny), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            verts.append(SDL_Vertex(position: SDL_FPoint(x: p2.x - nx, y: p2.y - ny), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            verts.append(SDL_Vertex(position: SDL_FPoint(x: p1.x - nx, y: p1.y - ny), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            idx.append(base)
            idx.append(base + 1)
            idx.append(base + 2)
            idx.append(base)
            idx.append(base + 2)
            idx.append(base + 3)
        }
        SDL_RenderGeometry(renderer, nil, verts, Int32(verts.count), idx, Int32(idx.count))
    }

    func fillPoly(_ pts: [SDL_FPoint], rgba: UInt32) {
        drawCalls += 1
        if pts.count < 3 { return }
        let color = fcolor(rgba)
        var verts = [SDL_Vertex]()
        verts.reserveCapacity(pts.count)
        for p in pts {
            verts.append(SDL_Vertex(position: p, color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
        }
        var idx = [Int32]()
        for i in 1..<(pts.count - 1) {
            idx.append(0)
            idx.append(Int32(i))
            idx.append(Int32(i + 1))
        }
        SDL_RenderGeometry(renderer, nil, verts, Int32(verts.count), idx, Int32(idx.count))
    }

    func circlePts(_ cx: Float, _ cy: Float, _ r: Float) -> [SDL_FPoint] {
        var out = [SDL_FPoint]()
        out.reserveCapacity(32)
        for i in 0..<32 {
            let t = Float(i) / 32 * 2 * Float.pi
            out.append(mat.apply(cx + r * SDL_cosf(t), cy + r * SDL_sinf(t)))
        }
        return out
    }

    func loadSound(_ name: String) -> Int32 {
        var base = name
        var lastSlash = -1
        var i = 0
        for ch in base.utf8 {
            if ch == 47 { lastSlash = i }
            i += 1
        }
        if lastSlash >= 0 {
            var bytes = Array(base.utf8)
            bytes.removeFirst(lastSlash + 1)
            bytes.append(0)
            base = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        if let id = soundNames[base] { return id }
        let id = Int32(soundSpecs.count)
        soundNames[base] = id
        var spec = SDL_AudioSpec()
        var buf: UnsafeMutablePointer<UInt8>? = nil
        var len: UInt32 = 0
        let path = assetDir + "/" + base
        _ = path.withCString { SDL_LoadWAV($0, &spec, &buf, &len) }
        soundSpecs.append(spec)
        soundBufs.append(buf)
        soundLens.append(len)
        return id
    }

    func play(_ id: Int32, volume: Float, loop: Bool) {
        let i = Int(id)
        guard i > 0, i < soundBufs.count, let buf = soundBufs[i] else { return }
        var spec = soundSpecs[i]
        guard let stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil) else { return }
        _ = SDL_SetAudioStreamGain(stream, volume)
        _ = SDL_PutAudioStreamData(stream, buf, Int32(soundLens[i]))
        if loop { _ = SDL_PutAudioStreamData(stream, buf, Int32(soundLens[i])) }
        _ = SDL_FlushAudioStream(stream)
        _ = SDL_ResumeAudioStreamDevice(stream)
        streams.append(stream)
        if streams.count > 24 {
            SDL_DestroyAudioStream(streams.removeFirst())
        }
    }

    // Store: "key\tvalue\n" lines through SDL's file API (no Foundation).
    func storeGet(_ key: String) -> String? {
        for i in 0..<storeKeys.count where storeKeys[i] == key { return storeVals[i] }
        return nil
    }

    func storeSet(_ key: String, _ val: String) {
        for i in 0..<storeKeys.count where storeKeys[i] == key {
            storeVals[i] = val
            saveStore()
            return
        }
        storeKeys.append(key)
        storeVals.append(val)
        saveStore()
    }

    func saveStore() {
        var out = [UInt8]()
        for i in 0..<storeKeys.count {
            out.append(contentsOf: Array(storeKeys[i].utf8))
            out.append(9)
            out.append(contentsOf: Array(storeVals[i].utf8))
            out.append(10)
        }
        _ = storePath.withCString { path in
            out.withUnsafeBufferPointer { SDL_SaveFile(path, $0.baseAddress, $0.count) }
        }
    }

    func loadStore() {
        var size = 0
        let data = storePath.withCString { SDL_LoadFile($0, &size) }
        guard let data else { return }
        let bytes = UnsafeRawPointer(data).bindMemory(to: UInt8.self, capacity: size)
        var field = [UInt8]()
        var key = ""
        for i in 0..<size {
            let ch = bytes[i]
            if ch == 9 {
                field.append(0)
                key = field.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                field = []
            } else if ch == 10 {
                field.append(0)
                let val = field.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                field = []
                storeKeys.append(key)
                storeVals.append(val)
            } else {
                field.append(ch)
            }
        }
        SDL_free(data)
    }
}

let host = Host()

// MARK: - wasmtime trampoline: env pointer carries the function index

let fnNames = [
    "gfx_clear", "gfx_save", "gfx_restore", "gfx_translate", "gfx_rotate",
    "gfx_scale", "gfx_set_alpha", "gfx_stroke_poly", "gfx_fill_poly",
    "gfx_fill_circle", "gfx_stroke_circle", "gfx_fill_rect", "gfx_stroke_rect",
    "evt_poll", "snd_by_name", "snd_play", "store_get", "store_set",
]

func fval(_ args: UnsafePointer<wasmtime_val_t>?, _ i: Int) -> Float {
    let v = args![i]
    if v.kind == UInt8(WASMTIME_F32) { return v.of.f32 }
    if v.kind == UInt8(WASMTIME_F64) { return Float(v.of.f64) }
    return Float(v.of.i32)
}

func ival(_ args: UnsafePointer<wasmtime_val_t>?, _ i: Int) -> Int32 {
    let v = args![i]
    if v.kind == UInt8(WASMTIME_I32) { return v.of.i32 }
    if v.kind == UInt8(WASMTIME_F32) { return Int32(v.of.f32) }
    return Int32(v.of.f64)
}

func uval(_ args: UnsafePointer<wasmtime_val_t>?, _ i: Int) -> UInt32 {
    UInt32(bitPattern: ival(args, i))
}

let trampoline: wasmtime_func_callback_t = { env, _, args, nargs, results, nresults in
    let fn = Int(bitPattern: env) - 1
    var ret: Int32 = 0
    switch fn {
    case 0: // gfx_clear
        host.mat = Mat()
        host.stack = []
        host.alpha = 1
        let c = host.fcolor(uval(args, 0))
        _ = SDL_SetRenderDrawColorFloat(host.renderer, c.r, c.g, c.b, 1)
        _ = SDL_RenderClear(host.renderer)
    case 1: host.stack.append(host.mat)
    case 2: if let m = host.stack.popLast() { host.mat = m }
    case 3: host.mat.mul(Mat(a: 1, b: 0, c: 0, d: 1, e: fval(args, 0), f: fval(args, 1)))
    case 4:
        let r = fval(args, 0) * Float.pi / 180
        host.mat.mul(Mat(a: SDL_cosf(r), b: SDL_sinf(r), c: -SDL_sinf(r), d: SDL_cosf(r), e: 0, f: 0))
    case 5: host.mat.mul(Mat(a: fval(args, 0), b: 0, c: 0, d: fval(args, 1), e: 0, f: 0))
    case 6: host.alpha = fval(args, 0)
    case 7: // gfx_stroke_poly
        let n = Int(ival(args, 1))
        let f = host.floats(ival(args, 0), n * 2)
        var pts = [SDL_FPoint]()
        pts.reserveCapacity(n)
        for i in 0..<n { pts.append(host.mat.apply(f[i * 2], f[i * 2 + 1])) }
        host.strokePoly(pts, closed: ival(args, 2) != 0, thickness: fval(args, 3), rgba: uval(args, 4))
    case 8: // gfx_fill_poly
        let n = Int(ival(args, 1))
        let f = host.floats(ival(args, 0), n * 2)
        var pts = [SDL_FPoint]()
        pts.reserveCapacity(n)
        for i in 0..<n { pts.append(host.mat.apply(f[i * 2], f[i * 2 + 1])) }
        host.fillPoly(pts, rgba: uval(args, 2))
    case 9: host.fillPoly(host.circlePts(fval(args, 0), fval(args, 1), fval(args, 2)), rgba: uval(args, 3))
    case 10:
        host.strokePoly(host.circlePts(fval(args, 0), fval(args, 1), fval(args, 2)),
                        closed: true, thickness: fval(args, 3), rgba: uval(args, 4))
    case 11:
        let x = fval(args, 0), y = fval(args, 1), w = fval(args, 2), h = fval(args, 3)
        host.fillPoly([host.mat.apply(x, y), host.mat.apply(x + w, y),
                       host.mat.apply(x + w, y + h), host.mat.apply(x, y + h)], rgba: uval(args, 4))
    case 12:
        let x = fval(args, 0), y = fval(args, 1), w = fval(args, 2), h = fval(args, 3)
        host.strokePoly([host.mat.apply(x, y), host.mat.apply(x + w, y),
                         host.mat.apply(x + w, y + h), host.mat.apply(x, y + h)],
                        closed: true, thickness: fval(args, 4), rgba: uval(args, 5))
    case 13: // evt_poll
        if host.events.isEmpty {
            ret = 0
        } else {
            let e = host.events.removeFirst()
            host.writeI32(ival(args, 0), e.0)
            host.writeI32(ival(args, 1), e.1)
            host.writeI32(ival(args, 2), e.2)
            host.writeI32(ival(args, 3), e.3)
            host.writeI32(ival(args, 4), e.4)
            ret = 1
        }
    case 14: ret = host.loadSound(host.str(ival(args, 0), ival(args, 1)))
    case 15:
        host.play(ival(args, 0), volume: fval(args, 1), loop: ival(args, 2) != 0)
        ret = ival(args, 0)
    case 16: // store_get
        if let v = host.storeGet(host.str(ival(args, 0), ival(args, 1))) {
            let bytes = Array(v.utf8)
            let cap = Int(ival(args, 3))
            let n = min(bytes.count, cap)
            for i in 0..<n { host.memoryBase![Int(ival(args, 2)) + i] = bytes[i] }
            ret = Int32(n)
        } else {
            ret = -1
        }
    case 17: host.storeSet(host.str(ival(args, 0), ival(args, 1)), host.str(ival(args, 2), ival(args, 3)))
    default:
        break
    }
    if nresults > 0 {
        results![0].kind = UInt8(WASMTIME_I32)
        results![0].of.i32 = ret
    }
    return nil
}

func fnIndex(_ name: String) -> Int {
    for (i, n) in fnNames.enumerated() where n == name { return i }
    return -1
}

// SDL scancode -> SFML key code (the ABI's event vocabulary)
func sfKey(_ scancode: UInt32) -> Int32 {
    switch scancode {
    case UInt32(SDL_SCANCODE_LEFT.rawValue): return 71
    case UInt32(SDL_SCANCODE_RIGHT.rawValue): return 72
    case UInt32(SDL_SCANCODE_UP.rawValue): return 73
    case UInt32(SDL_SCANCODE_DOWN.rawValue): return 74
    case UInt32(SDL_SCANCODE_SPACE.rawValue): return 57
    case UInt32(SDL_SCANCODE_ESCAPE.rawValue): return 36
    case UInt32(SDL_SCANCODE_RETURN.rawValue): return 58
    case UInt32(SDL_SCANCODE_BACKSPACE.rawValue): return 59
    case UInt32(SDL_SCANCODE_TAB.rawValue): return 60
    case UInt32(SDL_SCANCODE_A.rawValue)...UInt32(SDL_SCANCODE_Z.rawValue):
        return Int32(scancode - UInt32(SDL_SCANCODE_A.rawValue))
    case UInt32(SDL_SCANCODE_1.rawValue)...UInt32(SDL_SCANCODE_9.rawValue):
        return Int32(27 + scancode - UInt32(SDL_SCANCODE_1.rawValue))
    case UInt32(SDL_SCANCODE_0.rawValue): return 26
    default: return -1
    }
}

// MARK: - main

@main
enum Main {
    static func main() {
        var wasmPath = "../asteroidz-web/web/asteroidz-embedded.wasm"
        if let p = ("ASTEROIDZ_WASM".withCString { SDL_getenv($0) }) { wasmPath = String(cString: p) }
        var selftest: Float = 0
        if let s = ("ASTEROIDZ_SELFTEST".withCString { SDL_getenv($0) }) { selftest = Float(SDL_strtod(s, nil)) }

        var dirBytes = Array(wasmPath.utf8)
        var slash = -1
        for (i, ch) in dirBytes.enumerated() where ch == 47 { slash = i }
        if slash >= 0 {
            dirBytes.removeSubrange((slash + 1)...)
        } else {
            dirBytes = []
        }
        dirBytes.append(0)
        let wasmDir = dirBytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        host.assetDir = wasmDir + "assets/sfx"
        host.storePath = wasmDir + ".native-store.tsv"
        host.loadStore()

        guard SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) else { fatalError("SDL_Init failed") }
        var window: OpaquePointer? = nil
        var renderer: OpaquePointer? = nil
        let ok = "AsteroidZ - Embedded Swift native (SDL3 + wasmtime)".withCString {
            SDL_CreateWindowAndRenderer($0, 1280, 720, 0, &window, &renderer)
        }
        guard ok else { fatalError("SDL_CreateWindowAndRenderer failed") }
        _ = SDL_SetRenderLogicalPresentation(renderer, Int32(LOGICAL_W), Int32(LOGICAL_H),
                                             SDL_LOGICAL_PRESENTATION_LETTERBOX)
        _ = SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND)
        host.renderer = renderer

        // wasmtime: engine + store + WASI + linker with the env surface bound
        let engine = wasm_engine_new()
        let wstore = wasmtime_store_new(engine, nil, nil)
        let context = wasmtime_store_context(wstore)
        let wasiConfig = wasi_config_new()
        wasi_config_inherit_stdout(wasiConfig)
        wasi_config_inherit_stderr(wasiConfig)
        _ = wasmtime_context_set_wasi(context, wasiConfig)

        var size = 0
        let wasmData = wasmPath.withCString { SDL_LoadFile($0, &size) }
        guard let wasmData else { fatalError("wasm not found - run asteroidz-web/build-embedded.sh first") }
        var module: OpaquePointer? = nil
        _ = wasmtime_module_new(engine, UnsafeRawPointer(wasmData).bindMemory(to: UInt8.self, capacity: size),
                                size, &module)
        guard let module else { fatalError("wasm compile failed") }
        SDL_free(wasmData)

        let linker = wasmtime_linker_new(engine)
        _ = wasmtime_linker_define_wasi(linker)

        var importTypes = wasm_importtype_vec_t()
        wasmtime_module_imports(module, &importTypes)
        var bound = 0
        var stubbed = 0
        for i in 0..<importTypes.size {
            guard let imp = importTypes.data[i] else { continue }
            let modName = wasm_importtype_module(imp)!.pointee
            var isEnv = modName.size == 3
            if isEnv {
                isEnv = modName.data[0] == 101 && modName.data[1] == 110 && modName.data[2] == 118
            }
            guard isEnv else { continue }
            let nm = wasm_importtype_name(imp)!.pointee
            var nameBytes = [UInt8]()
            for j in 0..<nm.size { nameBytes.append(UInt8(bitPattern: nm.data[j])) }
            nameBytes.append(0)
            let name = nameBytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard let ftype = wasm_externtype_as_functype_const(wasm_importtype_type(imp)) else { continue }
            let idx = fnIndex(name)
            let env = UnsafeMutableRawPointer(bitPattern: idx + 1)
            _ = name.withCString { cname in
                "env".withCString { cenv in
                    wasmtime_linker_define_func(linker, cenv, 3, cname, name.utf8.count,
                                                ftype, trampoline, env, nil)
                }
            }
            if idx >= 0 { bound += 1 } else { stubbed += 1 }
        }

        var instance = wasmtime_instance_t()
        var trap: OpaquePointer? = nil
        let err = wasmtime_linker_instantiate(linker, context, module, &instance, &trap)
        guard err == nil, trap == nil else { fatalError("instantiate failed") }

        func export(_ name: String) -> wasmtime_extern_t {
            var ext = wasmtime_extern_t()
            _ = name.withCString { wasmtime_instance_export_get(context, &instance, $0, name.utf8.count, &ext) }
            return ext
        }

        var memExt = export("memory")

        func call(_ name: String, _ arg: Double? = nil) {
            var fn = export(name)
            var trap: OpaquePointer? = nil
            if let arg {
                var a = wasmtime_val_t()
                a.kind = UInt8(WASMTIME_F64)
                a.of.f64 = arg
                _ = wasmtime_func_call(context, &fn.of.func, &a, 1, nil, 0, &trap)
            } else {
                _ = wasmtime_func_call(context, &fn.of.func, nil, 0, nil, 0, &trap)
            }
            if trap != nil { fatalError("wasm trapped") }
        }

        host.memoryBase = wasmtime_memory_data(context, &memExt.of.memory)
        call("_initialize")
        call("boot")
        print("AsteroidZ native: Embedded host + Embedded cartridge, \(bound) env fns live, \(stubbed) stubbed")

        var running = true
        var elapsedMs: Float = 0
        var frames = 0
        var last = SDL_GetTicksNS()
        var sentStart = false
        var sentThrust = false

        while running {
            var e = SDL_Event()
            while SDL_PollEvent(&e) {
                if e.type == SDL_EVENT_QUIT.rawValue {
                    running = false
                } else if e.type == SDL_EVENT_KEY_DOWN.rawValue || e.type == SDL_EVENT_KEY_UP.rawValue {
                    let sf = sfKey(e.key.scancode.rawValue)
                    if sf >= 0, !e.key.`repeat` {
                        let t: Int32 = e.type == SDL_EVENT_KEY_DOWN.rawValue ? 5 : 6
                        let shift: Int32 = (UInt32(e.key.mod) & SDL_KMOD_SHIFT) != 0 ? 1 : 0
                        host.events.append((t, sf, shift, 0, 0))
                    }
                } else if e.type == SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue || e.type == SDL_EVENT_MOUSE_BUTTON_UP.rawValue {
                    _ = SDL_ConvertEventToRenderCoordinates(renderer, &e)
                    let t: Int32 = e.type == SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue ? 9 : 10
                    host.events.append((t, 0, Int32(e.button.x), Int32(e.button.y), 0))
                } else if e.type == SDL_EVENT_MOUSE_MOTION.rawValue {
                    _ = SDL_ConvertEventToRenderCoordinates(renderer, &e)
                    host.events.append((11, Int32(e.motion.x), Int32(e.motion.y), 0, 0))
                }
            }

            let now = SDL_GetTicksNS()
            var dt = Float(now - last) / 1_000_000
            last = now
            if dt > 50 { dt = 50 }

            // memory can grow mid-play; re-derive the base every frame
            host.memoryBase = wasmtime_memory_data(context, &memExt.of.memory)
            call("frame", Double(dt))
            _ = SDL_RenderPresent(renderer)

            frames += 1
            elapsedMs += dt
            if selftest > 0 {
                if elapsedMs >= 1000, !sentStart {
                    sentStart = true
                    host.events.append((5, 57, 0, 0, 0))
                    host.events.append((6, 57, 0, 0, 0))
                }
                if elapsedMs >= 2000, !sentThrust {
                    sentThrust = true
                    host.events.append((5, 73, 0, 0, 0))
                }
                if elapsedMs >= selftest * 1000 {
                    if let surf = SDL_RenderReadPixels(renderer, nil) {
                        _ = "native-selftest.bmp".withCString { SDL_SaveBMP(surf, $0) }
                        SDL_DestroySurface(surf)
                    }
                    print("selftest: \(frames) frames, \(host.drawCalls) draw calls -> native-selftest.bmp")
                    running = false
                }
            }

            let used = SDL_GetTicksNS() - now
            if used < 16_666_666 { SDL_DelayNS(16_666_666 - used) }
        }

        SDL_Quit()
    }
}
