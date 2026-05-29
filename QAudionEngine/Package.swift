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
        // Thin fork of microsoft/onnxruntime-swift-package-manager at 1.24.2.
        // The upstream repo has 58 MB of git history (old binary blobs) that makes
        // `git clone` take 60+ minutes on GitHub Actions macOS runners → CI timeout.
        // This fork is identical source-code-wise but has a single clean commit
        // (490 KB clone vs 58 MB), reducing onnxruntime resolution to <5 seconds.
        // The binary artifact (pod-archive-onnxruntime-c-1.24.2.zip ~52 MB) still
        // downloads from download.onnxruntime.ai — checksum unchanged.
        .package(url: "https://github.com/sigarone/onnxruntime-spm", exact: "1.24.2"),
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
        // GRDB 7.x requires swift-tools-version 6.1.0 (Xcode 16.3+); CI runner has
        // Xcode 16.2 (Swift tools 6.0) which is incompatible. Pin to 6.x until CI
        // upgrades to Xcode 16.3+.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.3"),
        // W610 (PENDING): iCepa/Tor.swift — embedded Tor for iOS.
        // The SPM package URL https://github.com/iCepa/Tor.swift returns 404 on
        // GitHub Actions — the repo does not exist at that path. Dependency
        // temporarily removed; EmbeddedTorManager compiles against the stub branch
        // (#else of #if canImport(Tor)) which throws TorError.notAvailable so
        // TorObfsTransport falls back to external Orbot (port 9050).
        // TODO: locate the correct SPM-compatible Tor XCFramework URL and re-add.
        // Candidates: https://github.com/iCepa/Tor.framework (Obj-C, needs wrapper)
        //             or a third-party SPM mirror of the Tor binary.
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
                .product(name: "onnxruntime", package: "onnxruntime-spm"),
                .product(name: "WebRTC", package: "WebRTC"),
                .product(name: "GRDB", package: "GRDB.swift"),
                // Tor.swift removed — see W610 note in dependencies above.
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
