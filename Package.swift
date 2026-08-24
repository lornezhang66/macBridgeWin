// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "macbridge", targets: ["MacBridge"]),
        .library(name: "MacBridgeCore", targets: ["MacBridgeCore"])
    ],
    targets: [
        .target(name: "MacBridgeCore"),
        .executableTarget(name: "MacBridge", dependencies: ["MacBridgeCore"]),
        .testTarget(name: "MacBridgeCoreTests", dependencies: ["MacBridgeCore"])
    ]
)
