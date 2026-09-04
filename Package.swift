// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "TapKey",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TapKey", targets: ["TapKey"])
    ],
    targets: [
        .executableTarget(
            name: "TapKey",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(name: "TapKeyTests", dependencies: ["TapKey"])
    ]
)
