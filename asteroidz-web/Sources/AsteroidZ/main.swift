import SpriteKit
import KitABI

// Reactor-mode wasm entry. The runtime calls _initialize once, then boot()
// brings up the SKView and the game scene (the same construction the macOS
// ViewController performs), and frame() advances one animation frame.

nonisolated(unsafe) var view: SKView? = nil

private func bootBody() {
    let v = SKView()
    v.ignoresSiblingOrder = true
    v.showsFPS = false
    v.shouldCullNonVisibleNodes = true
    v.allowsTransparency = true
    v.preferredFramesPerSecond = 60

    let scene = GameScene(size: CGSize(width: 1920, height: 1080))
    scene.scaleMode = .aspectFill
    v.presentScene(scene)
    view = v
}

#if hasFeature(Embedded)
@_cdecl("boot")
public func boot() { bootBody() }

@_cdecl("frame")
public func frame(_ dtMs: Double) { view?.tick(dtMs) }
#else
@_cdecl("boot")
public func boot() { MainActor.assumeIsolated { bootBody() } }

@_cdecl("frame")
public func frame(_ dtMs: Double) { MainActor.assumeIsolated { view?.tick(dtMs) } }
#endif
