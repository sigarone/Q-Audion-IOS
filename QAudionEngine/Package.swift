// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QAudionEngine",
    platforms: [
        .iOS(.v16),
        // macOS floor raised 13 -> 14 so `swift build` / `swift test` on the macOS CI runner
        // (engine-tests.yml) actually RESOLVES: the onnxruntime-spm product requires macOS 14,
        // and SwiftPM refuses to resolve when the library floor (13) is below a dependency's (14).
        // iOS floor is unchanged (.v16); the iOS app ships from xcodebuild, not `swift build`, so
        // this only affects the macOS Swift-package test build. (Without this, engine-tests.yml
        // fails at resolution but the `swift build 2>&1 | tail -100` pipe masked the exit code,
        // so it reported a false green — see Phase-3 PR notes.)
        .macOS(.v14)
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
        // Binaries hosted on GitHub Releases (sigarone CDN) — no more throttling
        // from download.onnxruntime.ai which was capping CI runners at ~5 KB/s.
        .package(url: "https://github.com/sigarone/onnxruntime-spm", exact: "1.24.2"),
        // W347: WebRTC binary framework. Thin fork of stasel/WebRTC with 1 commit
        // and binary hosted on GitHub Releases (sigarone CDN) for fast CI downloads.
        // Same checksum as stasel/WebRTC 147.0.0 — binary is identical.
        .package(url: "https://github.com/sigarone/webrtc-spm", exact: "147.0.0"),
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
        // ─────────────────────────────────────────────────────────────────────────────────────
        //  PHASE-1 INTEGRATION — v4 PQ ratchet C ABI (default-OFF; see RatchetNative)
        //
        //  Real XCFramework published to sigarone/qaudion-crypto-core v0.1.0 (2026-06-19).
        //  `RatchetNative.available` returns true when this binary is linked on arm64.
        //  `V4_NATIVE_RATCHET_ENABLED = false` — the path remains inert until Pavel sign-off.
        // ─────────────────────────────────────────────────────────────────────────────────────
        .binaryTarget(
            name: "CQaudionCryptoCore",
            url: "https://github.com/sigarone/qaudion-crypto-core-spm/releases/download/v0.1.3/QaudionCryptoCore.xcframework.zip",
            checksum: "d918ed92cf0d54a451357392e96b05bf2849bc88626bed55dc527fd286b4d1ab"
        ),
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
                "CQaudionCryptoCore",  // Phase 3: v4 PQ ratchet C ABI (default-OFF; see above)
                .product(name: "onnxruntime", package: "onnxruntime-spm"),
                .product(name: "WebRTC", package: "webrtc-spm"),
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
                .copy("Video/Resources/sframe-video-kat.json"),
                .copy("Crypto/Resources/handshake-sig-kat.json"),
                .copy("Resources/kat/kms-psk-v2-kat.json"),
                .copy("Resources/kat/kms-pop-v1-kat.json"),
                // kms-rotation-v2 Phase-1 frozen KATs (byte-copies of
                // apps/qaudion-firmware/tools/kat/kms-v2/{session-key-v3,hs-bundle-v1}-kat.json).
                // session-KDF schema:3 (info_v3 = label||ct_bind||selected_fp_or_zero32)
                // + the D3-WIRE signed hs-bundle-v1 canon (Ed25519 OFFER/ACCEPT).
                .copy("Resources/kat/session-key-v3-kat.json"),
                .copy("Resources/kat/hs-bundle-v1-kat.json"),
                .copy("Integration/Resources/earbud-excl-v2-kat.json")
            ]
        )
    ]
)
