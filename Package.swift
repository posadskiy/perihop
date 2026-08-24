// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PeriHop",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PeriHop",
            path: "Sources/PeriHop",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "PeriHopTests",
            dependencies: ["PeriHop"],
            path: "Tests/PeriHopTests"
        )
    ]
)
