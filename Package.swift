// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "speedtest",
    platforms: [
        .macOS(.v12), .iOS(.v15)
    ],
    products: [
        .library(name: "speedtest", targets: ["speedtest"]),
    ],
    targets: [
        .target(
            name: "speedtest",
            path: "src"
        ),
    ]
)