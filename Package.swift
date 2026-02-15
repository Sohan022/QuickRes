// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "QuickRes",
    platforms: [
        .macOS(.v12),
    ],
    targets: [
        .executableTarget(
            name: "QuickRes",
            path: "Sources"
        ),
    ]
)
