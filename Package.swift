// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QuickTrans",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuickTrans",
            path: "Sources/QuickTrans",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
    ]
)
