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
        //  PHASE-3 INTEGRATION — v4 PQ "continuum" ratchet C ABI (default-OFF; see RatchetNative)
        //
        //  `CQaudionCryptoCore` exposes the shared Rust crypto core's stable C ABI
        //  (sigarone/qaudion-crypto-core, src/ffi.rs) to Swift via the cbindgen header
        //  (include/qaudion_crypto_core.h) + module.modulemap. `RatchetNative.swift` imports it.
        //
        //  ⚠ The header is the byte-identical cbindgen output; the .c is a FAIL-CLOSED PLACEHOLDER
        //    stub (qaudion_crypto_core_stub.c) so the package compiles + links + tests GREEN before
        //    the real binary is published. `RatchetNative.available` is `false` while only the stub
        //    is linked, so the v4 path is inert (exactly like Android when libqaudion_crypto_core.so
        //    is absent). `MessageRatchet.v4NativeRatchetEnabled` is `false` regardless.
        //
        //  TO ACTIVATE THE REAL CORE (when the XCFramework is published from crypto-core ios.yml):
        //    1. Remove this `CQaudionCryptoCore` plain C target.
        //    2. Add a binaryTarget instead, e.g.:
        //         .binaryTarget(
        //             name: "CQaudionCryptoCore",
        //             url: "https://github.com/sigarone/qaudion-crypto-core/releases/download/<tag>/QaudionCryptoCore.xcframework.zip",
        //             checksum: "<value from `swift package compute-checksum` printed by ios.yml>"
        //         )
        //       (SwiftPM binaryTargets accept a remote zip+checksum OR a local .xcframework path.)
        //    3. Delete Sources/CQaudionCryptoCore/ (the XCFramework carries its own header+modulemap).
        //    The `RatchetNative.swift` Swift source is unchanged across this swap — it links the same
        //    `import CQaudionCryptoCore` module name either way.
        // ─────────────────────────────────────────────────────────────────────────────────────
        .target(
            name: "CQaudionCryptoCore",
            path: "Sources/CQaudionCryptoCore",
            publicHeadersPath: "include",
            cSettings: [
                // The stub .c does `#include "qaudion_crypto_core.h"`; ensure include/ is on its
                // own compile search path (same pattern as the CLiboqs target below).
                .headerSearchPath("include"),
            ]
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
                .copy("Crypto/Resources/handshake-sig-kat.json")
            ]
        )
    ]
)
