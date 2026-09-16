// swift-tools-version: 5.9
import PackageDescription

let sceneEngineLibrary = Context.packageDirectory + "/.build/scene-engine"

let package = Package(
    name: "Muro",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "CSceneEngine",
            path: "Sources/CSceneEngine"
        ),
        .target(
            name: "MuroKit",
            dependencies: ["CSceneEngine"],
            path: "Sources/MuroKit",
            linkerSettings: [
                .unsafeFlags(["-L", sceneEngineLibrary]),
                .linkedLibrary("wer_ffi"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("objc"),
                .linkedLibrary("iconv"),
            ]
        ),
        .executableTarget(
            name: "muro-app",
            dependencies: ["MuroKit"],
            path: "Sources/MuroApp"
        ),
        .executableTarget(
            name: "muro-engine",
            dependencies: ["MuroKit"],
            path: "Sources/MuroEngine"
        ),
        .executableTarget(
            name: "muro-import",
            dependencies: ["MuroKit"],
            path: "Sources/MuroImport"
        ),
        .executableTarget(
            name: "muro-set",
            dependencies: ["MuroKit"],
            path: "Sources/MuroSet"
        ),
        .executableTarget(
            name: "muro-publish",
            dependencies: ["MuroKit"],
            path: "Sources/MuroPublish"
        ),
        .executableTarget(
            name: "muro-prepare",
            dependencies: ["MuroKit"],
            path: "Sources/MuroPrepare"
        ),
        .testTarget(
            name: "MuroKitTests",
            dependencies: ["MuroKit"],
            path: "Tests/MuroKitTests"
        )
    ]
)
