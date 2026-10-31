// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ColimaDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ColimaDeck",
            path: "Sources/ColimaDeck"
        )
    ]
)
