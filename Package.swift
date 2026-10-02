// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrphanBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "OrphanBar", path: "Sources/OrphanBar"),
    ]
)
