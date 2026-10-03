// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuBarFold",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MenuBarFold",
            path: "Sources/MenuBarFold"
        )
    ]
)
