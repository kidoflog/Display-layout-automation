// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DisplayHeight",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DisplayHeight", targets: ["DisplayHeight"])
    ],
    targets: [
        .target(name: "DisplayHeightCore"),
        .executableTarget(name: "DisplayHeight", dependencies: ["DisplayHeightCore"]),
        .executableTarget(name: "LayoutChecks", dependencies: ["DisplayHeightCore"], path: "Checks")
    ]
)
