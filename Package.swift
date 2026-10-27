// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StatusSync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "StatusSync", path: "Sources/StatusSync")
    ]
)
