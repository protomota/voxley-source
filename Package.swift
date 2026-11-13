// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Voxley",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Voxley", targets: ["Voxley"])],
    targets: [
        .executableTarget(name: "Voxley"),
        .testTarget(name: "VoxleyTests", dependencies: ["Voxley"])
    ]
)
