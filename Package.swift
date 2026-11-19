// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "QuickAsk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuickAsk",
            path: "Sources/QuickAsk",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
