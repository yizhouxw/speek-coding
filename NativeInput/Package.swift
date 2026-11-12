// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NativeInput",
    platforms: [.macOS(.v13)],
    products: [.library(name: "NativeInput", targets: ["NativeInput"]),
        .executable(name: "native-input-diagnose", targets: ["NativeInputDiagnostics"])],
    targets: [
        .target(name: "NativeInput"),
        .executableTarget(name: "NativeInputDiagnostics", dependencies: ["NativeInput"]),
        .testTarget(name: "NativeInputTests", dependencies: ["NativeInput"])
    ]
)
