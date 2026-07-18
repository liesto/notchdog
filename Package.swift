// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SessionNotch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SessionNotchCore", targets: ["SessionNotchCore"]),
        .executable(name: "SessionNotch", targets: ["SessionNotchApp"]),
    ],
    targets: [
        .target(name: "SessionNotchCore"),
        .executableTarget(
            name: "SessionNotchApp",
            dependencies: [
                "SessionNotchCore",
            ]
        ),
        .executableTarget(name: "SessionNotchTests", dependencies: ["SessionNotchCore"]),
    ]
)
