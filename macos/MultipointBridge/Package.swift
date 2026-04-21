// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MultipointBridgeMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MultipointBridgeMac", targets: ["MultipointBridgeMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", from: "125.0.0")
    ],
    targets: [
        .executableTarget(
            name: "MultipointBridgeMac",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC")
            ],
            path: "Sources/MultipointBridgeMac"
        )
    ]
)
