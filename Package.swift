// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Watt",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WattCore", targets: ["WattCore"]),
        .executable(name: "Watt", targets: ["Watt"]),
    ],
    targets: [
        .target(name: "WattCore"),
        .executableTarget(
            name: "Watt",
            dependencies: ["WattCore"],
            path: "Sources/Watt",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "WattCoreTests",
            dependencies: ["WattCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
