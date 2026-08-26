// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fling",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FlingKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FlingKitTests", dependencies: ["FlingKit"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
