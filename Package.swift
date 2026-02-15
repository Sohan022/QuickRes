// swift-tools-version: 6.1
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
