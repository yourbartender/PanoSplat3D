// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PanoSplat3D",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "PanoSplat3D",
            targets: ["PanoSplat3D"]
        ),
        .library(
            name: "PanoSplat3DCore",
            targets: ["PanoSplat3DCore"]
        )
    ],
    targets: [
        .target(
            name: "PanoSplat3DCore",
            path: "Sources/PanoSplat3DCore",
            resources: [
                .copy("Resources/Shaders"),
                .copy("Resources/Sounds")
            ]
        ),
        .executableTarget(
            name: "PanoSplat3D",
            dependencies: ["PanoSplat3DCore"],
            path: "Sources/PanoSplat3D"
        ),
        .testTarget(
            name: "PanoSplat3DTests",
            dependencies: ["PanoSplat3DCore"],
            path: "Tests/PanoSplat3DTests"
        )
    ]
)
