// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WiFiLogger",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "wifi-logger", targets: ["WiFiLogger"])],
    targets: [
        .executableTarget(name: "WiFiLogger"),
        .testTarget(name: "WiFiLoggerTests", dependencies: ["WiFiLogger"]),
    ]
)
