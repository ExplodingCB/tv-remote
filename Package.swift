// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TVRemote",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "TVRemote",
            path: "Sources/TVRemote",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
