// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SupernoteKit",
    platforms: [.macOS(.v13), .iOS("26.0")],
    products: [
        .library(name: "SupernoteKit", targets: ["SupernoteKit"]),
        .executable(name: "snrender", targets: ["snrender"]),
    ],
    targets: [
        // Optimized in debug builds too: the per-pixel loops are ~30× slower unoptimized, which
        // makes large notebooks take minutes when the apps run from Xcode.
        .target(name: "SupernoteKit", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .executableTarget(name: "snrender", dependencies: ["SupernoteKit"]),
        .testTarget(name: "SupernoteKitTests", dependencies: ["SupernoteKit"]),
    ]
)
