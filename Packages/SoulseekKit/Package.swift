// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SoulseekKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SoulseekKit", targets: ["SoulseekKit"]),
    ],
    targets: [
        // zlib ships with both the iOS SDK and Linux (zlib1g-dev), so a system module is enough.
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "SoulseekKit", dependencies: ["CZlib"]),
        .testTarget(name: "SoulseekKitTests", dependencies: ["SoulseekKit"]),
    ]
)
