// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Notchlight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Notchlight", targets: ["Notchlight"]),
        .executable(name: "NotchlightSignal", targets: ["NotchlightCLI"]),
        .library(name: "BorderOverlay", targets: ["BorderOverlay"])
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "StatusSignals"),
        .executableTarget(name: "NotchlightCLI", dependencies: ["StatusSignals"]),
        .target(name: "Diagnostics"),
        .target(name: "BorderOverlay", dependencies: ["Diagnostics"]),
        .target(name: "CodexIntegration", dependencies: ["Diagnostics"]),
        .target(name: "WidgetShared"),
        .target(name: "WidgetViews", dependencies: ["WidgetShared"]),
        .executableTarget(name: "Notchlight", dependencies: ["BorderOverlay", "CodexIntegration", "Diagnostics", "WidgetShared", "StatusSignals", .product(name: "Sparkle", package: "Sparkle")],
                          resources: [.copy("Resources/Legal")]),
        .testTarget(name: "StatusSignalsTests", dependencies: ["StatusSignals"]),
        .testTarget(name: "BorderOverlayTests", dependencies: ["BorderOverlay"]),
        .testTarget(name: "NotchlightTests", dependencies: ["Notchlight"]),
        .testTarget(name: "CodexIntegrationTests", dependencies: ["CodexIntegration"]),
        .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics"]),
        .testTarget(name: "WidgetSharedTests", dependencies: ["WidgetShared"])
    ],
    swiftLanguageModes: [.v6]
)
