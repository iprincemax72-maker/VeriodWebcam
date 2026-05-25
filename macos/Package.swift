// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VeriodWebcam",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VeriodWebcam", targets: ["VeriodWebcam"])
    ],
    targets: [
        .executableTarget(
            name: "VeriodWebcam",
            path: "Sources/VeriodWebcam"
        )
    ]
)
