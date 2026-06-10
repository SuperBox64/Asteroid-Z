// Direct-native entry: the same SKView + GameScene construction the wasm
// main performs, driven by an SDL frame loop instead of a browser.
import SpriteKit
import CSDL3

@main
enum Main {
    static func main() {
        kitHostInit()

        let v = SKView()
        v.ignoresSiblingOrder = true
        v.showsFPS = false
        v.shouldCullNonVisibleNodes = true
        v.allowsTransparency = true
        v.preferredFramesPerSecond = 60

        let scene = GameScene(size: CGSize(width: 1920, height: 1080))
        scene.scaleMode = .aspectFill
        v.presentScene(scene)

        var last = SDL_GetTicksNS()
        var selftestMs: Float = 0
        var selftest: Float = 0
        if let s = ("ASTEROIDZ_SELFTEST".withCString { SDL_getenv($0) }) {
            selftest = Float(SDL_strtod(s, nil))
        }
        var sentStart = false
        var sentThrust = false
        var frames = 0

        while kitHostPump() {
            let now = SDL_GetTicksNS()
            var dt = Float(now - last) / 1_000_000
            last = now
            if dt > 50 { dt = 50 }

            v.tick(Double(dt))
            kitHostPresent()

            frames += 1
            if selftest > 0 {
                selftestMs += dt
                if selftestMs >= 1000, !sentStart {
                    sentStart = true
                    Kit.shared.events.append((5, 57, 0, 0, 0))
                    Kit.shared.events.append((6, 57, 0, 0, 0))
                }
                if selftestMs >= 2000, !sentThrust {
                    sentThrust = true
                    Kit.shared.events.append((5, 73, 0, 0, 0))
                }
                if selftestMs >= selftest * 1000 {
                    if let surf = SDL_RenderReadPixels(Kit.shared.renderer, nil) {
                        _ = "direct-selftest.bmp".withCString { SDL_SaveBMP(surf, $0) }
                        SDL_DestroySurface(surf)
                    }
                    print("selftest: \(frames) frames -> direct-selftest.bmp")
                    break
                }
            }

            let used = SDL_GetTicksNS() - now
            if used < 16_666_666 { SDL_DelayNS(16_666_666 - used) }
        }
        SDL_Quit()
    }
}
