// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NativeInput",
    platforms: [.macOS(.v13)],
    products: [.library(name: "NativeInput", targets: ["NativeInput"]),
        .executable(name: "native-input-diagnose", targets: ["NativeInputDiagnostics"]),
        .executable(name: "dji-input-diagnose", targets: ["DJIDiagnostics"])],
    targets: [
        .target(name: "NativeInput"),
        .executableTarget(name: "DJIDiagnostics", dependencies: ["NativeInput"]),
        .executableTarget(name: "NativeInputDiagnostics", dependencies: ["NativeInput"]),
        .testTarget(name: "NativeInputTests", dependencies: ["NativeInput"])
    ]
)
