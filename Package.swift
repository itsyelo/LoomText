// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LoomText",
    // macOS is declared for the headless test/CI path only; the
    // rendering surface (LoomLabel/LoomAsyncLayer) is UIKit-gated.
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "LoomText", targets: ["LoomText"])
    ],
    targets: [
        // Swift 6 language mode — strict concurrency is the default.
        .target(
            name: "LoomText"
        ),
        .testTarget(
            name: "LoomTextTests",
            dependencies: ["LoomText"]
        )
    ]
)
