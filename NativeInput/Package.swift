// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NativeInput",
    platforms: [.macOS(.v13)],
    products: [.library(name: "NativeInput", targets: ["NativeInput"])],
    targets: [
        .target(name: "NativeInput"),
        .testTarget(name: "NativeInputTests", dependencies: ["NativeInput"])
    ]
)
