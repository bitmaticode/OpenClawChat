// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OpenClawWS",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "OpenClawWS", targets: ["OpenClawWS"])
    ],
    targets: [
        .target(name: "OpenClawWS"),
        .testTarget(name: "OpenClawWSTests", dependencies: ["OpenClawWS"])
    ]
)
