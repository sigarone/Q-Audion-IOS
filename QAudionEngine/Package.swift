// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Reality.xcframework is built on-demand by scripts/build-reality-xcframework.sh
// (CI: the "Build reality xcframework" step in ios-testflight.yml and
// engine-tests.yml's ios-simulator-tests job) — it is NOT committed to git and
// is absent on any job that doesn't run that step (e.g. the macOS-native
// `swift test` job, which has no Xcode/gomobile step for it and would fail
// package resolution outright on a missing local-path binaryTarget). Resolved
// dynamically here instead of declared unconditionally so resolution never
// hard-fails wherever the file doesn't exist — RealityManager.swift's
// `#if canImport(Reality)` real branch compiles only where it's actually
// present, its stub `#else` branch everywhere else, exactly like before.
let realityXcframeworkPath = "../QAudionApp/Vendor/Reality.xcframework"
let hasRealityXcframework = FileManager.default.fileExists(atPath: realityXcframeworkPath)

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
        // WebRTC is a local .binaryTarget (see `targets`) — webrtc-sdk (LiveKit
        // ecosystem) build 144.7559.10 WITH H265/HEVC (VideoToolbox
        // RTCVideoEncoderH265/RTCVideoDecoderH265). The old stasel/sigarone fork
        // (M147) had NO H265 encoder → iOS offered only H264/VP8/VP9/AV1 while
        // Android is H265-only → SDP video negotiated codec=null. Module/API
        // unchanged (`import WebRTC`, RTC*) so it is a drop-in. (No `.package`
        // line — a binaryTarget needs no dependency entry.)
        // W500: GRDB for local persistence (conversation + message store).
        // Note: GRDB-SQLCipher is NOT a valid SPM product in groue/GRDB.swift —
        // SQLCipher integration is available only via CocoaPods/xcframework.
        // Using standard GRDB; iOS Data Protection (FileProtectionType) provides
        // at-rest encryption when the device is locked.
        // GRDB 7.x requires swift-tools-version 6.1.0 (Xcode 16.3+); CI runner has
        // Xcode 16.2 (Swift tools 6.0) which is incompatible. Pin to 6.x until CI
        // upgrades to Xcode 16.3+.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.3"),
        // W-GRPLIVEKIT: self-hosted LiveKit SFU for group calls (audio, +video
        // later) with native per-participant E2EE (RTCFrameCryptor). Pinned to
        // an EXACT tag (not `from:`) — same discipline as onnxruntime-spm above.
        //
        // Version pin rationale (CORRECTED 2026-07-14 after a CI resolution
        // failure): this repo builds with **swift-tools-version 5.9** (line 1)
        // and CI runs **Xcode 15.4 / Swift 5.10** (see kat-cross-platform.yml
        // `xcode-select .../Xcode_15.4.app`). LiveKit >= 2.14.0 declares
        // swift-tools-version 6.0, which a Swift-5.10 toolchain CANNOT resolve
        // ("incompatible tools version (6.0.0)"), so 2.14.1 broke the build.
        // **2.13.0 is the newest tag whose manifest declares swift-tools-version
        // 5.9** — resolvable by Xcode 15.4. Its E2EE API is identical to 2.14.x
        // for everything used here (verified against the tagged source), EXCEPT
        // it has no `keyDerivationAlgorithm` option: 2.13.0 derives the frame
        // key with PBKDF2 UNCONDITIONALLY (the `.pbkdf2`/`.hkdf` toggle is 2.14+),
        // which is exactly the cross-platform contract. Bump this pin to >= 2.14
        // only together with (or after) bumping CI's Xcode to >= 16.0, and
        // re-add `keyDerivationAlgorithm: .pbkdf2` explicitly when you do.
        //
        // Dual-WebRTC safety (verified against the actual sources before
        // adding this, not assumed): `client-sdk-swift` depends on its OWN
        // WebRTC build via `livekit/webrtc-xcframework` — module name
        // `LiveKitWebRTC` (product `LiveKitWebRTC`), NOT `WebRTC`. That
        // fork renames the framework bundle `WebRTC.framework` ->
        // `LiveKitWebRTC.framework` AND prefixes every Objective-C symbol
        // with `LK` (RTCPeerConnection -> LKRTCPeerConnection, etc. — see
        // livekit/webrtc-xcframework's "Symbol Namespace Isolation" docs)
        // SPECIFICALLY so it can coexist in the same binary as any other
        // WebRTC-based library. So this app's own custom-patched `WebRTC`
        // binaryTarget below (webrtc-aes256-build, also M144.7559.x
        // upstream) and LiveKit's `LiveKitWebRTC` (2.13.0 pins
        // webrtc-xcframework 144.7559.03) can link into the same app
        // without file- or symbol-level collisions: two independent WebRTC
        // engines, one per call type (1:1 calls keep using this app's own
        // `WebRTC`/`QAudionPeerConnection`; group-call SFU media uses
        // LiveKit's `LiveKitWebRTC` end-to-end, entirely inside
        // `LiveKitGroupCallRoom`). Residual (non-blocking) risk: both
        // engines each own an independent AVAudioSession wrapper
        // (`RTCAudioSession` vs `LKRTCAudioSession`) around the SAME
        // system-singleton `AVAudioSession` — fine today since 1:1 and
        // group calls are mutually exclusive call states, but a future
        // call-waiting/concurrent-call scenario would need explicit
        // handoff between the two.
        // AES-256 fork (sigarone/client-sdk-swift, tag 2.13.0-aes256-livekit):
        // redirects ONLY the transitive webrtc-xcframework dependency to
        // sigarone/webrtc-xcframework's own aes256-livekit fork, which
        // carries the same aes256-framecryptor.patch as this app's own
        // WebRTC binaryTarget below — group-call media now gets AES-256-GCM
        // instead of the fixed AES-128 FrameCryptor once a 32-byte shared
        // key is supplied (matches the Android wiring, feature-call's
        // configurations.all { resolutionStrategy.dependencySubstitution }).
        // Every other file/line in client-sdk-swift 2.13.0 is untouched —
        // this is a same-tag-shape fork, not a rewrite. All the Dual-WebRTC
        // safety analysis above still applies unchanged (package/symbol
        // relocation is baked into the xcframework itself, independent of
        // which URL serves it).
        //
        // Build-history note (2026-07-15/16): the FIRST xcframework this fork
        // pointed at was built from webrtc_ref=m144_release (a rolling
        // branch), whose tip had drifted ~2.5 months past
        // livekit/webrtc-xcframework's real 144.7559.03 cut and broke THIS
        // package's own compile (LKRTCAudioDeviceModule missing
        // isVoiceProcessingEnabled — client-sdk-swift's AudioManager.swift
        // calls it directly). Fixed at the source: sigarone/webrtc-aes256-build's
        // build-livekit-ios.yml now pins an exact commit (via a tag on a
        // sigarone/webrtc fork, since GitHub won't shallow-fetch an
        // arbitrary SHA) and the xcframework was rebuilt+republished under
        // the SAME release asset URL. No change needed here — this comment
        // exists only to force a fresh SPM resolution in CI so the new
        // checksum gets picked up (Package.resolved caching could otherwise
        // mask a stale binary).
        //
        // W-GRPKEY256 (2026-07-20 lockstep flag day): tag 2.13.1-aes256-raw is
        // 2.13.0-aes256-livekit + EXACTLY ONE commit (9255cb3, fork branch
        // aes256-raw): a raw-Data `setKey(keyData:participantId:index:)`
        // overload on `BaseKeyProvider` that hands the bytes VERBATIM to
        // `LKRTCFrameCryptorKeyProvider` (the String overload UTF-8-encodes,
        // so a 44-char base64 key can never fire the patched native
        // `password.size() == 32 ? 256 : 128` gate — the whole fleet was
        // silently deriving AES-128-GCM). `LiveKitGroupCallRoom` now feeds
        // the RAW 32-byte SK_0 through this overload -> native derives
        // AES-256-GCM. Nothing else differs from the analysis above.
        .package(url: "https://github.com/sigarone/client-sdk-swift.git", exact: "2.13.1-aes256-raw"),
        // W610 (PENDING): iCepa/Tor.swift — embedded Tor for iOS.
        // The SPM package URL https://github.com/iCepa/Tor.swift returns 404 on
        // GitHub Actions — the repo does not exist at that path. Dependency
        // temporarily removed; EmbeddedTorManager compiles against the stub branch
        // (#else of #if canImport(Tor)) which throws TorError.notAvailable so
        // TorObfsTransport falls back to external Orbot (port 9050).
        // TODO: locate the correct SPM-compatible Tor XCFramework URL and re-add.
        // Candidates: https://github.com/iCepa/Tor.framework (Obj-C, needs wrapper)
        //             or a third-party SPM mirror of the Tor binary.
        //
        // REALITY: RealityManager.swift's real `#if canImport(Reality)` branch is wired
        // below — see `hasRealityXcframework` at the top of this file for how the
        // binaryTarget/dependency are added only where QAudionApp/Vendor/Reality.xcframework
        // actually exists (built by scripts/build-reality-xcframework.sh, iOS-only,
        // .iOS platform condition on the target dependency).
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
            // v0.1.4 — core @ b868067 (same core as the live Android .so / Desktop .node):
            // adds the empty-plaintext v4-decrypt fix + C-ABI catch_unwind hardening; v4 wire/
            // derivation byte-identical to v0.1.3 (WIRE-FORMAT §4 + Model A) so iOS v4 interops.
            url: "https://github.com/sigarone/qaudion-crypto-core-spm/releases/download/v0.1.4/QaudionCryptoCore.xcframework.zip",
            checksum: "892c956caacd5dd911a617136f9f60de3340d9552d940ba87fa892d6877efc05"
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
                ]),
            ]
        ),
        .target(
            name: "QAudionVPIOSafe",
            path: "Sources/QAudionVPIOSafe",
            publicHeadersPath: "include"
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
        // WebRTC with H265/HEVC + AES-256-GCM FrameCryptor — patched build of
        // webrtc-sdk M144 (same RTC* API as 144.7559.10). Single-hunk patch:
        // DeriveKeys(..., password.size()==32?256:128) forces AES-256-GCM when
        // a 32-byte K_video is set (stock binary hardcodes 128). H265 enabled
        // (rtc_use_h265=true). Built via sigarone/webrtc-aes256-build@webrtc-ios-aes256-m144.
        // Checksum = SHA256(WebRTC.xcframework.zip).
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/sigarone/webrtc-aes256-build/releases/download/webrtc-ios-aes256-m144/WebRTC.xcframework.zip",
            checksum: "44f0779e18e86c9b65e03592ee8d28d667d8bc3218fc401f4c7f393353fbb410"
        ),
        .target(
            name: "QAudionEngine",
            dependencies: [
                "CLiboqs",
                "COpus",
                "QAudionVPIOSafe",  // W-GRPVPIO-CRASH-5: ObjC @try/@catch shim so an
                                    // uncatchable AVFAudio NSException from
                                    // setVoiceProcessingEnabled degrades instead of SIGABRT
                "CQaudionCryptoCore",  // Phase 3: v4 PQ ratchet C ABI (default-ON since 2026-06-27; see above)
                .product(name: "onnxruntime", package: "onnxruntime-spm"),
                "WebRTC",  // local binaryTarget (webrtc-sdk H265 build) — see below
                .product(name: "GRDB", package: "GRDB.swift"),
                // W-GRPLIVEKIT: group-call SFU media transport — see the
                // dependency comment above for the dual-WebRTC coexistence
                // rationale (LK-prefixed symbols, renamed framework bundle).
                .product(name: "LiveKit", package: "client-sdk-swift"),
                // Tor.swift removed — see W610 note in dependencies above.
            ] + (hasRealityXcframework ? [.target(name: "Reality", condition: .when(platforms: [.iOS]))] : []),
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
                .copy("Crypto/Resources/psk-mix-v1-kat.json"),
                // WIRE_SPEC §3.3.1 blinded PSK advertisement. Written here by
                // bcrypto-server/tools/kat/gen_psk_advert_v3_kat.py, which emits all
                // six fleet copies in one run so they cannot drift apart.
                .copy("Crypto/Resources/psk-advert-v3-kat.json"),
                .copy("Resources/kat/kms-psk-v2-kat.json"),
                .copy("Resources/kat/kms-pop-v1-kat.json"),
                // kms-rotation-v2 Phase-1 frozen KATs (byte-copies of
                // apps/qaudion-firmware/tools/kat/kms-v2/{session-key-v3,hs-bundle-v1}-kat.json).
                // session-KDF schema:3 (info_v3 = label||ct_bind||selected_fp_or_zero32)
                // + the D3-WIRE signed hs-bundle-v1 canon (Ed25519 OFFER/ACCEPT).
                .copy("Resources/kat/session-key-v3-kat.json"),
                .copy("Resources/kat/hs-bundle-v1-kat.json"),
                // gap A2 / ADR-014a — vendored byte-copy of
                // apps/qaudion-android-new/qaudion-engine/src/test/resources/kms-prebootstrap-kat.json.
                // Structural/ad_bytes fidelity fence for KmsPreBootstrapCbor +
                // KmsPreBootstrap (random per-run key material, see the
                // vector's own "notes" field — NOT bit-reproduced by encode()).
                .copy("Resources/kat/kms-prebootstrap-kat.json"),
                .copy("Integration/Resources/earbud-excl-v2-kat.json")
            ]
        )
    ] + (hasRealityXcframework ? [
        Target.binaryTarget(name: "Reality", path: realityXcframeworkPath),
    ] : [])
)
