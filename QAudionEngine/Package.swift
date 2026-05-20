// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QAudionEngine",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "QAudionEngine",
            targets: ["QAudionEngine"]
        )
    ],
    dependencies: [
        // Pinned exact because onnxruntime XCFrameworks have historically shipped
        // with elevated MinimumOSVersion (e.g. iOS 18.1) that triggers ITMS-90208.
        // 1.24.2 declares iOS 15+ in its Package.swift — safe for our iOS 16 target.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
        // W347: WebRTC binary framework (community-maintained build of Google's libwebrtc).
        // stasel/WebRTC ships an XCFramework with arm64 (device) + arm64/x86_64 (simulator).
        // Pinned to a known-good iOS 16-compatible release. The IPA size impact is
        // significant (~150 MB) but unavoidable for cross-platform 1:1 + group calls.
        .package(url: "https://github.com/stasel/WebRTC", exact: "147.0.0"),
        // W500: GRDB for local persistence (conversation + message store).
        // Note: GRDB-SQLCipher is NOT a valid SPM product in groue/GRDB.swift —
        // SQLCipher integration is available only via CocoaPods/xcframework.
        // Using standard GRDB; iOS Data Protection (FileProtectionType) provides
        // at-rest encryption when the device is locked.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    ],
    targets: [
        .target(
            name: "CLiboqs",
            path: "Sources/CLiboqs",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("src/mlkem"),
                .headerSearchPath("src/common"),
                .headerSearchPath("src/common/sha3"),
                .headerSearchPath("src/common/sha3/xkcp_low/KeccakP-1600/plain-64bits"),
                .headerSearchPath("src/common/pqclean_shims"),
                // OQS_ENABLE_KEM_ml_kem_1024 already in oqsconfig.h
                // MLK_CONFIG_PARAMETER_SET already in mlkem_native_config.h
                .define("MLK_CONFIG_FILE", to: "\"mlkem_native_config.h\""),
                // Suppress all warnings-as-errors for mlkem-native C code
                // Required for Release/Archive builds on iOS device (arm64)
                .unsafeFlags([
                    "-Wno-error=implicit-function-declaration",
                    "-Wno-error",
                    "-Wno-shorten-64-to-32",
                    "-Wno-unused-but-set-variable",
                    "-Wno-unreachable-code",
                    "-w",  // Suppress ALL warnings
                ]),
            ]
        ),
        .target(
            name: "COpus",
            path: "Sources/COpus",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("include/opus"),
                .headerSearchPath("src"),
                .headerSearchPath("src/opus_src"),
                .headerSearchPath("src/celt"),
                .headerSearchPath("src/silk"),
                .headerSearchPath("src/silk/fixed"),
                .headerSearchPath("src/silk/float"),
                .define("HAVE_CONFIG_H"),
                .define("OPUS_BUILD"),
            ]
        ),
        .target(
            name: "QAudionEngine",
            dependencies: [
                "CLiboqs",
                "COpus",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "WebRTC", package: "WebRTC"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/QAudionEngine",
            resources: [
                .copy("Resources/aasist_raw_base_maxdata_int8.onnx"),
                .copy("Resources/aasist_raw_small_distill_int8.onnx")
            ]
        ),
        .testTarget(
            name: "QAudionEngineTests",
            dependencies: ["QAudionEngine"],
            path: "Tests/QAudionEngineTests",
            resources: [
                .copy("../Resources/cross_platform_vectors.json"),
                .copy("Video/Resources/sframe-video-kat.json")
            ]
        )
    ]
)
