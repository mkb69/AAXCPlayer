// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AAXCPlayer",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "AAXCPlayer",
            targets: ["AAXCPlayer"]
        ),
        .executable(
            name: "aaxc-tool",
            targets: ["AAXCTool"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AAXCPlayer",
            dependencies: []
        ),
        .executableTarget(
            name: "AAXCTool",
            dependencies: ["AAXCPlayer"]
        ),
        .testTarget(
            name: "AAXCPlayerTests",
            dependencies: ["AAXCPlayer"]
        )
    ]
)