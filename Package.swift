// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRPeek",
    platforms: [.macOS(.v14)], // logic builds 14+; the app target uses macOS 26 features at runtime
    targets: [
        .target(name: "PRPeekCore"),
        .executableTarget(
            name: "PRPeek",
            dependencies: ["PRPeekCore"]
        ),
        .testTarget(
            name: "PRPeekCoreTests",
            dependencies: ["PRPeekCore"]
        ),
    ]
)
