// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Headroom", path: "Sources/Headroom")
    ]
)
