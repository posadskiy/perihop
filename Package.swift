// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PeriHop",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PeriHop",
            path: "Sources/PeriHop",
            exclude: ["Info.plist"]
        )
    ]
)
