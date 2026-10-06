// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Glance",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Glance",
            path: "Sources/Glance",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
