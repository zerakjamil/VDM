// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VortexDownloadManager",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Vortex", targets: ["Vortex"])
    ],
    targets: [
        .executableTarget(
            name: "Vortex",
            path: "Sources/Vortex"
        ),
        .testTarget(
            name: "VortexTests",
            dependencies: ["Vortex"],
            path: "Tests/VortexTests"
        )
    ]
)
