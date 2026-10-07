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
        // WebRTC is a local .binaryTarget (see `targets`): the strict M150 build with H265/HEVC
        // (VideoToolbox RTCVideoEncoderH265/RTCVideoDecoderH265), AES-256 only. Android is
        // H265-only, so the iOS build must offer H265 too, else the SDP video negotiates
        // codec=null. Module/API: `import WebRTC`, RTC*. (No `.package` line — a binaryTarget
        // needs no dependency entry.)
        // W500: GRDB for local persistence (conversation + message store).
        // Note: GRDB-SQLCipher is NOT a valid SPM product in groue/GRDB.swift —
        // SQLCipher integration is available only via CocoaPods/xcframework.
        // Using standard GRDB; iOS Data Protection (FileProtectionType) provides
        // at-rest encryption when the device is locked.
        // GRDB 7.x requires swift-tools-version 6.1.0 (Xcode 16.3+). Was pinned to
        // 6.x while CI ran Xcode 16.2; bumped 2026-07-28 now that every CI workflow
        // builds with Xcode 26.6 (see engine-tests.yml/kat-cross-platform.yml/
        // ios-testflight.yml). QAudionEngine's own swift-tools-version (5.9, top of
        // this file) is unaffected — a package can depend on a higher-swift-tools-
        // version package as long as the actual toolchain resolves it.
        // MASVS I5 (2026-08-21) — switched from `from:` to `exact:`, matching
        // onnxruntime-spm's own pin below and every other dependency in this
        // manifest that has a committed Package.resolved to anchor an exact
        // version against (`from:` lets a future `swift package update` drift
        // to any 7.x without anyone noticing). 7.11.1 is the version this
        // package actually resolved to, confirmed via the real CI-produced
        // Package.resolved now committed at
        // QAudionApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        // Group media runs on the ONE strict WebRTC binaryTarget below (the same
        // `RTCPeerConnectionFactory` as 1:1 calls), against qjanus (Janus VideoRoom) with native
        // FrameCryptor E2EE — see `GroupCall/`.
        // W610 (REMOVED 2026-09-14): embedded Tor support for iOS has been
        // removed entirely, on every platform, not just deprioritized here.
        // Product decision: this app's censorship-bypass need is bypassing
        // blocked/closed networks, not anonymity — Tor's fixed ~300-800ms
        // per-hop latency (3-hop onion circuit) materially degrades
        // real-time voice, and the app shipped no pluggable-transport
        // bridges (no obfs4/meek/snowflake), so plain Tor was often blocked
        // outright by real state-level censorship anyway (well-known guard-
        // relay IPs get blocklisted). `EmbeddedTorManager` and
        // `TorObfsTransport` were deleted along with this dependency entry
        // (they only ever compiled against the `#else` stub branch — the
        // SPM package URL https://github.com/iCepa/Tor.swift 404s, so a
        // working embedded Tor build never actually shipped on iOS). Do not
        // re-attempt sourcing a working Tor SPM package — this line of work
        // is closed. The Reality/xray-core integration that briefly
        // replaced it was itself removed 2026-09-18 (no upside for the
        // App-Review-surface cost); iOS ships no dedicated censorship-bypass
        // transport today.
    ],
    targets: [
        // ─────────────────────────────────────────────────────────────────────────────────────
        //  v4 PQ ratchet C ABI — LIVE (see RatchetNative)
        //
        //  Real XCFramework published to sigarone/qaudion-crypto-core v0.1.0 (2026-06-19).
        //  `RatchetNative.available` returns true when this binary is linked on arm64.
        //
        //  Corrected 2026-08-11. This block said "default-OFF" and
        //  "`V4_NATIVE_RATCHET_ENABLED = false` — the path remains inert until
        //  Pavel sign-off". Both were stale: sign-off happened 2026-06-27 and
        //  MessageRatchet.swift:82 has read `v4NativeRatchetEnabled = true` since
        //  go-live a3f00d6. A comment that describes a shipped feature as inert
        //  is how a live path gets "cleaned up" by someone who trusted it.
        // ─────────────────────────────────────────────────────────────────────────────────────
        .binaryTarget(
            name: "CQaudionCryptoCore",
            // v0.1.5 — core @ 79822fe (2026-09-16): adds the v5 dual-channel ratchet C ABI
            // (qa_dual_root_0/qa_session_init_channel/qa_ratchet_encrypt_v5/qa_ratchet_decrypt_v5)
            // that this repo's RatchetNative.swift/MessageRatchet.swift CONTROL-channel wiring
            // calls — purely additive, v4 wire/derivation byte-identical to v0.1.4 (unaffected).
            // Bumped specifically to unblock that wiring, which would not otherwise LINK against
            // the older pin (those 4 symbols didn't exist in v0.1.4's header/binary).
            url: "https://github.com/sigarone/qaudion-crypto-core-spm/releases/download/v0.1.5/QaudionCryptoCore.xcframework.zip",
            checksum: "d6166f677f4dd2af98d1a4c629a5e0ecd24e450e1fbbb981e6305f02958248db"
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
                // Deep PLC (FARGAN). The DNN kernels dispatch to plain C here —
                // this build defines no OPUS_HAVE_RTCD — but the arch header
                // directories still have to be reachable, because `dnn/vec.h`
                // and several celt headers include `x86/...` and `arm/...`
                // paths UNCONDITIONALLY, outside any architecture guard. Only
                // the headers are vendored; none of the SIMD .c files are.
                .headerSearchPath("src/dnn"),
                .define("HAVE_CONFIG_H"),
                .define("OPUS_BUILD"),
            ]
        ),
        // WebRTC with H265/HEVC + AES-256-GCM FrameCryptor — patched build of
        // webrtc-sdk M144 (same RTC* API as 144.7559.10). Two patches applied
        // in sequence: (1) DeriveKeys(..., password.size()==32?256:128) forces
        // AES-256-GCM when a 32-byte frame key is set (stock binary hardcodes
        // 128); (2) native-pli.patch (W-NATIVEPLI, 2026-08-26) adds an
        // unconditional, rate-limited FrameCryptionState.kDecryptionFailed
        // notification on a real decrypt-tag-mismatch — the native signal
        // Android's AAR rebuild added the same day (`project_aar_rebuild_
        // 2026_08_25` memory), ported here to close the iOS/Android parity
        // gap found `project_aar_ios_parity_audit_2026_08_26`. H265 enabled
        // (rtc_use_h265=true). Built via
        // sigarone/webrtc-aes256-build@webrtc-ios-aes256-m144-native-pli.
        // Checksum = SHA256(WebRTC.xcframework.zip), independently verified
        // against the GitHub release asset digest before this edit, not
        // just copied from the build log.
        //
        // 2026-09-25: SECURITY rebuild (release ...-native-pli-nokeylog, built by
        // sigarone/webrtc-aes256-build d22f11c, run 36064578582). Same WebRTC source
        // commit (webrtc-sdk/webrtc df1011beabae = m144_release tip when the previous
        // binary was built), same aes256 + native-pli patches, same Xcode 16.4.0 /
        // macos-15-arm64 image, plus no-key-log.patch: the upstream RTC_LOG(LS_INFO)
        // statements that printed the frame-cryptor secret / salt / DERIVED AES key are
        // gone (the build and scripts/ci/assert-no-key-logging.sh both scan every
        // Mach-O slice for derived_key / "slat << " / raw_key: 0 hits). Rollback: the
        // previous release webrtc-ios-aes256-m144-native-pli (sha256 dbaefe2aff6eabff...
        // 95701b9) is untouched.
        //
        // M150 hardened WebRTC, release webrtc-ios-m150-a256-dplc-10
        // (sigarone/webrtc-aes256-build, build run 36930666945, build repo main
        // e40bd3f9365a316d6b61ad5a2708d25d39fc5dae; the run and its "Gate G1-G9"
        // step concluded success, BUILDINFO.json lists every patch of the series
        // as present, build-provenance attestation verified for the zip). Same
        // base as dplc-9 and dplc-4 (webrtc-sdk/webrtc@ba469aa2093b,
        // BoringSSL@f91f1447, Opus@55513e81): strict transport (DTLS 1.3 +
        // TLS_AES_256_GCM_SHA384 only, SRTP AEAD_AES_256_GCM only,
        // X25519MLKEM768 first), FrameCryptor AES-256 only, deep PLC + OSCE,
        // FEC floor, P8 runtime tuning API, P12 receiver-side frame anti-replay
        // window (new in dplc-9: per-sender counter in the FrameCryptor IV,
        // replayed or too-old frames are dropped). New in dplc-10: P9
        // (stats-remote-cert-cache). libwebrtc's RTCStatsCollector cached the
        // certificate stats on the first getStats() and cleared that cache only on
        // SDP / ICE-candidate / data-channel changes, never when DTLS completed, so
        // a getStats() taken before the handshake had delivered the peer
        // certificate pinned remoteCertificateId = nil for the whole call. The
        // transcript-v5 DTLS fingerprint check (b) polls getStats() for that id and
        // fails closed after 5 s (local stage stats_timeout, wire reason
        // dtls_fp_mismatch), so every call that polled early could be ended without
        // any certificate mismatch. P9 (P9-stats-remote-cert-cache.patch) fixes that
        // cache natively. The -lk variant is no longer built. Device arm64 +
        // simulator arm64 only.
        // Checksum = SwiftPM checksum of the zip (SHA256 of WebRTC.xcframework.zip).
        // Provenance, all checked on 2026-10-02: `gh release download` of
        // WebRTC.xcframework.zip + SHA256SUMS + BUILDINFO.json, `sha256sum -c
        // SHA256SUMS` OK (40954758 bytes), the digest equal to the asset digest in
        // the release record and to the subject digest of the attestation, and
        // `gh attestation verify WebRTC.xcframework.zip --repo
        // sigarone/webrtc-aes256-build` succeeded (1 attestation: workflow
        // build-m150-ios.yml on main at e40bd3f9, run 36930666945, SLSA provenance
        // v1).
        // Rollback: the previous releases (webrtc-ios-m150-a256-dplc-9, whose
        // check (b) can time out because it lacks P9; webrtc-ios-m150-a256-dplc-4; and
        // the M144 nokeylog build webrtc-ios-aes256-m144-native-pli-nokeylog) stay
        // untouched.
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/sigarone/webrtc-aes256-build/releases/download/webrtc-ios-m150-a256-dplc-10/WebRTC.xcframework.zip",
            checksum: "83cfd351d6c4aced28a148b5f971f991db116c00690478b60f6840647b3d0fd5"
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
                // Tor.swift removed entirely (W610, 2026-09-14) — see note in dependencies above.
            ],
            path: "Sources/QAudionEngine",
            resources: [
                .copy("Resources/aasist_raw_base_maxdata_int8.onnx"),
                .copy("Resources/aasist_raw_small_distill_int8.onnx"),
                // 2026-08-01: CAM++ speaker embedder (Tier 1/Tier 2 voice
                // verification) — SAME asset Android already ships
                // (qaudion-engine/src/main/assets/models/campplus_sv_voxceleb_16k.onnx),
                // SHA-256 pinned in CamPlusSpeakerEmbedder.swift.
                .copy("Resources/campplus_sv_voxceleb_16k.onnx"),
                // 2026-09-02: AS-Norm impostor cohort for SpeakerCohortNormalizer
                // (RemoteSpeakerChangeMonitor's score feed) — SAME bytes Android
                // ships at qaudion-engine/src/main/assets/models/speaker_cohort_v1.bin
                // (80 x 512 float32 LE prototypes, no header). See that class's kdoc.
                .copy("Resources/speaker_cohort_v1.bin"),
                // Entitlement (EGT) signing pubkey pinned as a build asset,
                // design doc §3.5 — SAME bytes Android ships at
                // app/src/main/assets/bcrypto_entitlement_pubkey.pem.
                // ⚠️ PLACEHOLDER: a throwaway test keypair, not the real
                // server ent-v1 key (not issued yet). Loaded by
                // EntitlementPublicKey.swift; the ship-guard for swapping it
                // is EntitlementPublicKeyTests, currently skipped on purpose.
                .copy("Resources/bcrypto_entitlement_pubkey.pem"),
                // TRUST-2 (CRYPTO_PROTOCOL_AUDIT_2026-09-01.md) — DEDICATED
                // remote-wipe signing pubkey, deliberately a SEPARATE key
                // from the entitlement one above (different purpose,
                // different blast radius). Loaded by
                // WipeSigningPublicKey.swift; same placeholder/ship-guard
                // discipline as bcrypto_entitlement_pubkey.pem — see that
                // file's kdoc.
                .copy("Resources/wipe_signing_pubkey.pem")
            ]
        ),
        .testTarget(
            name: "QAudionEngineTests",
            // "CLiboqs" added for WireV1CrossPlatformKatTests — the
            // ML-KEM-1024 deterministic-seed KAT calls
            // OQS_KEM_ml_kem_1024_keypair_derand directly (no generic-handle
            // equivalent exists in liboqs; it's algorithm-specific).
            dependencies: ["QAudionEngine", "CLiboqs"],
            path: "Tests/QAudionEngineTests",
            resources: [
                // 2026-08-02: was "../Resources/cross_platform_vectors.json".
                // A resource declared OUTSIDE the target directory does not
                // end up in Bundle.module, so KatVectorsTests' five cases all
                // failed with "cross_platform_vectors.json not found in
                // Bundle.module" — which is why the whole class was skipped
                // on 2026-06-19 rather than root-caused. The file (and the two
                // kat/ vectors that sat beside it, declared with in-target
                // paths that did not exist) now lives inside the target.
                // These are the vectors that pin iOS byte-compatibility with
                // Android; having them excluded is what left the
                // cross-platform breakage this codebase keeps hitting without
                // any automated guard.
                .copy("Resources/cross_platform_vectors.json"),
                .copy("Video/Resources/sframe-video-kat.json"),
                .copy("Crypto/Resources/psk-mix-v1-kat.json"),
                // W-GRPAUDIOKEY (2026-08-27) — group-call SFU-outage
                // fallback-audio session/frame-key derivation, byte-for-byte
                // shared cross-platform with Desktop/Android (see
                // GroupAudioSessionKeyKatTests.swift + GroupSenderKey's
                // W-GRPAUDIOKEY extension).
                .copy("Crypto/Resources/group-audio-kat.json"),
                // WIRE_SPEC §3.3.1 blinded PSK advertisement. Written here by
                // bcrypto-server/tools/kat/gen_psk_advert_v3_kat.py, which emits all
                // six fleet copies in one run so they cannot drift apart.
                .copy("Crypto/Resources/psk-advert-v3-kat.json"),
                // Proximity pairing v1 (QR + Bluetooth LE, hybrid ML-KEM-1024) —
                // generated by scripts/kat/gen_proximity_pairing_kat.py, an
                // independent hashlib/hmac reference implementation of
                // docs/security/PROXIMITY_PAIRING_QR_BLE_SPEC.md. Android reuses it.
                .copy("Proximity/Resources/proximity-pairing-kat.json"),
                .copy("Resources/kat/kms-psk-v2-kat.json"),
                .copy("Resources/kat/kms-pop-v1-kat.json"),
                // kms-rotation-v2 Phase-1 frozen KATs (byte-copies of
                // apps/qaudion-firmware/tools/kat/kms-v2/{session-key-v3,hs-bundle-v1}-kat.json).
                // session-KDF schema:3 (info_v3 = label||ct_bind||selected_fp_or_zero32)
                // + the D3-WIRE signed hs-bundle-v1 canon (Ed25519 OFFER/ACCEPT).
                .copy("Resources/kat/hs-bundle-v1-kat.json"),
                // gap A2 / ADR-014a — vendored byte-copy of
                // apps/qaudion-android-new/qaudion-engine/src/test/resources/kms-prebootstrap-kat.json.
                // Structural/ad_bytes fidelity fence for KmsPreBootstrapCbor +
                // KmsPreBootstrap (random per-run key material, see the
                // vector's own "notes" field — NOT bit-reproduced by encode()).
                .copy("Resources/kat/kms-prebootstrap-kat.json"),
                .copy("Integration/Resources/earbud-excl-v2-kat.json"),
                // W-KEYSCRUB (2026-09-21) -- golden vectors of KeyMaterialScrubber, shared with
                // scripts/test_keymaterial_scrub_parity.py (the Python port); synthetic data only.
                .copy("Diagnostics/Resources/key-material-scrub-vectors.json"),
                // Cross-platform canonical vectors from bcrypto-server's
                // test/kat/wire_v1.0.0/ — see WireV1CrossPlatformKatTests.swift
                // and that repo's test/kat/README.md. VENDORED (bcrypto-server
                // is private, so CI can't curl it unauthenticated, and SPM
                // needs every declared resource to exist on disk regardless —
                // matches how every other KAT fixture in this file is handled).
                // Bump by hand when the source vectors change.
                .copy("Crypto/Resources/wire_v1.0.0/hkdf/expand.json"),
                // Renamed from derive.json in both subdirectories: SPM's
                // resource bundling requires basenames unique across the
                // WHOLE target, not just within their declared subdirectory
                // — "multiple resources named 'derive.json'" broke package
                // resolution entirely until this rename (2026-07-30).
                .copy("Crypto/Resources/wire_v1.0.0/x25519/x25519-derive.json"),
                .copy("Crypto/Resources/wire_v1.0.0/x25519/ecdh.json"),
                .copy("Crypto/Resources/wire_v1.0.0/aead_nonce/aead-nonce-derive.json"),
                .copy("Crypto/Resources/wire_v1.0.0/ml_kem_1024/keygen.json"),
                .copy("Crypto/Resources/wire_v1.0.0/ml_kem_1024/decap.json"),
                // Group calls v2 (spec 5.3): byte-exact frame-crypto vectors shared with the
                // desktop's frame cryptor (two senders, epochs 1..17, key ring wrap). Synthetic
                // keys only; see GroupE2eeKatTests.
                .copy("GroupCall/Resources/group-calls-v2-frame-crypto.json"),
                // Transcript v6 (caller SAS commitment + REVEAL) + DTLS fingerprint binding (WIRE_SPEC 3.7 / 3.8): byte-exact
                // transcripts, signatures, KDF / SAS / KCMAC and frame-key vectors, shared with the
                // desktop. Synthetic keys and certificates only; see HandshakeTranscriptV6Tests.
                .copy("Crypto/Resources/handshake-sig-v6-kat.json"),
                // File transfer v2 (WIRE_SPEC section 12): the known-answer vectors, a BYTE-FOR-BYTE copy of
                // bcrypto-server test/kat/file_v2/file-v2-kat.json (generated there by tools/katgen/filev2,
                // standard library only). Test keys only. FileV2KatTests pins the SHA-256 of this file, and
                // .gitattributes marks it -text so a CRLF checkout cannot change it. Re-copy it, never edit it.
                .copy("Resources/kat/file-v2-kat.json"),
                // File transfer v2, the server conformance transcript: a BYTE-FOR-BYTE copy of bcrypto-server
                // test/kat/file_v2_server/transcript.json at commit f541653b (a golden file generated from the real handlers of the
                // parts protocol; docs/FILES_V2_SERVER_TRANSCRIPT.md there describes it). The tests replay every scenario against the
                // in-memory fake of the server, FileV2ServerTranscriptTests pins its SHA-256, and .gitattributes marks it -text so a
                // CRLF checkout cannot change it. Re-copy it, never edit it.
                .copy("Resources/kat/file-v2-server-transcript.json")
            ]
        )
    ]
)
