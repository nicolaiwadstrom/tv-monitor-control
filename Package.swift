// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LGTVControl",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LGTVControl",
            path: "Sources/LGTVControl"
        )
    ]
)
