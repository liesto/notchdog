// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SessionNotch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SessionNotchCore", targets: ["SessionNotchCore"]),
        .executable(name: "SessionNotch", targets: ["SessionNotchApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.0.0"),
    ],
    targets: [
        .target(name: "SessionNotchCore"),
        .executableTarget(
            name: "SessionNotchApp",
            dependencies: [
                "SessionNotchCore",
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
            ]
        ),
        .executableTarget(name: "SessionNotchTests", dependencies: ["SessionNotchCore"]),
    ]
)
