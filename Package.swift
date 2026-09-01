// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DrivePurge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DrivePurge", targets: ["DrivePurge"])
    ],
    targets: [
        .executableTarget(
            name: "DrivePurge",
            path: "Sources"
        )
    ]
)
