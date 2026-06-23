// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CameraEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CameraEngine", targets: ["CameraEngine"]),
        .executable(name: "openxwebcam-capture", targets: ["CaptureCLI"]),
    ],
    targets: [
        .target(name: "CPTPTransport"),
        .target(name: "CameraEngine", dependencies: ["CPTPTransport"]),
        .executableTarget(name: "CaptureCLI", dependencies: ["CameraEngine"]),
        .testTarget(name: "CameraEngineTests", dependencies: ["CameraEngine"]),
    ]
)
