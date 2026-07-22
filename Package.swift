// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OLMBrowser",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OLMBrowser", targets: ["OLMBrowser"])
    ],
    targets: [
        .target(
            name: "CZipSupport",
            path: "Sources/CZipSupport",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "OLMBrowser",
            dependencies: ["CZipSupport"],
            path: "Sources/OLMBrowser"
        )
    ]
)
