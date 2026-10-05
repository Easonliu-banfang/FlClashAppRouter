// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FlClashAppRouter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FlClashAppRouter",
            path: "Sources"
        )
    ]
)
