// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Notchlight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Notchlight", targets: ["Notchlight"]),
        .library(name: "BorderOverlay", targets: ["BorderOverlay"])
    ],
    targets: [
        .target(name: "Diagnostics"),
        .target(name: "BorderOverlay", dependencies: ["Diagnostics"]),
        .target(name: "CodexIntegration", dependencies: ["Diagnostics"]),
        .executableTarget(name: "Notchlight", dependencies: ["BorderOverlay", "CodexIntegration", "Diagnostics"],
                          resources: [.copy("Resources/Legal")]),
        .testTarget(name: "BorderOverlayTests", dependencies: ["BorderOverlay"]),
        .testTarget(name: "NotchlightTests", dependencies: ["Notchlight"]),
        .testTarget(name: "CodexIntegrationTests", dependencies: ["CodexIntegration"]),
        .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics"])
    ],
    swiftLanguageModes: [.v6]
)
