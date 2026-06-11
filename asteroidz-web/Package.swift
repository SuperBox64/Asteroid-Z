// swift-tools-version:6.2
import PackageDescription

// AsteroidZ, SpriteKit edition, on wasm.
//
// A port of the macOS AsteroidZ SpriteKit game (../AsteroidZ) to WebAssembly
// via the SuperBox64 SpriteKit reimplementation. The game's `import SpriteKit`
// / `import GameController` lines work unchanged here: the package vends
// modules with those exact names. GameScene.swift is a symlink to the macOS
// master, so there is one game source.
let package = Package(
    name: "AsteroidZWeb",
    dependencies: [
        .package(url: "https://github.com/SuperBox64/SuperBox64Kit", branch: "embedded"),
    ],
    targets: [
        .executableTarget(
            name: "AsteroidZ",
            dependencies: [
                .product(name: "SpriteKit",      package: "SuperBox64Kit"),
                .product(name: "KitABI",         package: "SuperBox64Kit"),
                .product(name: "AppKit",         package: "SuperBox64Kit"),
                .product(name: "GameplayKit",    package: "SuperBox64Kit"),
                .product(name: "GameController", package: "SuperBox64Kit"),
                .product(name: "AVFoundation",   package: "SuperBox64Kit"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xclang-linker", "-mexec-model=reactor",
                    "-Xlinker", "--export=boot",
                    "-Xlinker", "--export=frame",
                    "-Xlinker", "--export-if-defined=_initialize",
                    "-Xlinker", "--allow-undefined",
                ]),
            ]
        ),
    ]
)
