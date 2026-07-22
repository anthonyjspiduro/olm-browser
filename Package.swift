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
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "CZipSupport",
            path: "Sources/CZipSupport",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "OLMBrowser",
            dependencies: ["CZipSupport", "CSQLite"],
            path: "Sources/OLMBrowser"
        )
    ]
)
