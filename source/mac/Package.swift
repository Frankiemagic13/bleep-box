// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BleepBox",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BleepBox",
            path: "Sources/BleepBox"
        )
    ]
)
