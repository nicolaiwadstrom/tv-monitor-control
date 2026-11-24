// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TVMonitorControl",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TVMonitorControl",
            path: "Sources/TVMonitorControl"
        )
    ]
)
