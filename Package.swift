// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchFlow",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "NotchFlow",
            path: "Sources/NotchFlow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
