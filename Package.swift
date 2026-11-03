// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallScribe",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "CallScribe", targets: ["CallScribe"]),
        .executable(name: "callscribe-cli", targets: ["CallScribeCLI"]),
        .library(name: "CallScribeCore", targets: ["CallScribeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1")
    ],
    targets: [
        .target(
            name: "CallScribeCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .target(
            name: "CallScribeCapture",
            dependencies: ["CallScribeCore"]
        ),
        .executableTarget(
            name: "CallScribe",
            dependencies: ["CallScribeCore", "CallScribeCapture"]
        ),
        .executableTarget(
            name: "CallScribeCLI",
            dependencies: ["CallScribeCore", "CallScribeCapture"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
