// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QAudionEngine",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "QAudionEngine",
            targets: ["QAudionEngine"]
        )
    ],
    targets: [
        .target(
            name: "QAudionEngine",
            path: "Sources/QAudionEngine"
        ),
        .testTarget(
            name: "QAudionEngineTests",
            dependencies: ["QAudionEngine"],
            path: "Tests/QAudionEngineTests",
            resources: [
                .copy("../Resources/cross_platform_vectors.json")
            ]
        )
    ]
)
