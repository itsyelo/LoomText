// swift-tools-version: 5.9
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
        .target(
            name: "LoomText",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "LoomTextTests",
            dependencies: ["LoomText"]
        )
    ]
)
