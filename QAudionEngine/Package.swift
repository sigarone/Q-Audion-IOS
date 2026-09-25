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
        // W-GRPLIVEKIT: self-hosted LiveKit SFU for group calls (audio, +video
        // later) with native per-participant E2EE (RTCFrameCryptor). Pinned to
        // an EXACT tag (not `from:`) — same discipline as onnxruntime-spm above.
        //
        // BUMPED 2026-07-28 to 2.15.1-aes256-raw2 — the REAL root cause of
        // "nobody ever receives anything from iOS in a group call".
        // `E2EEManager.addRtpSender` created the frame cryptor and set only
        // `.delegate`/`.enabled`, never `.keyIndex`, so it kept the native
        // default `key_index_ = 0`; the ENCRYPT path looks up exactly that
        // slot and `GetKeySet(0) == nullptr` makes `encryptFrame` report
        // kMissingKey and RETURN WITHOUT emitting the frame — zero RTP leaves
        // the device, and the SFU times the publish out at +30s. This app
        // installs keys at `groupEpoch % 16`, which is 1/2/3 and provably
        // never 0. RECEIVE was unaffected because decryption reads the index
        // from the frame trailer instead. Device-confirmed: 12/12 local
        // tracks (AUDIO AND VIDEO) missing_key, 0 ok, over three days.
        // client-sdk-android has always pinned this (E2EEManager.kt:199) and
        // client-sdk-js re-reads it per frame; Swift had neither. raw2 adds
        // `BaseKeyProvider.getLatestKeyIndex(_:)` + the pin on sender and
        // receiver. No xcframework rebuild needed — `RTCFrameCryptor.keyIndex`
        // is already public/assign in the pinned webrtc-sdk m144_release.
        // NOTE: the codec note below was a REAL but SEPARATE bug (the empty
        // simulcastCodecs mimeType). Fixing it removed the noise that was
        // hiding this one; it was never sufficient on its own.
        //
        // RESTORED 2026-07-28 to 2.15.1-aes256-raw after root-causing (and
        // fixing) the group-video publish break, briefly worked around by
        // reverting to 2.13.1-aes256-raw earlier the same day. The real bug
        // was NOT in this fork/version: fi-1's LiveKit server logs showed
        // iOS's camera addTrackRequest.simulcastCodecs[0] arriving with NO
        // mime type ("simulcast codec without mime type"), because
        // `LiveKitGroupCallRoom`'s `RoomOptions` never set
        // `defaultVideoPublishOptions.preferredCodec` — every other
        // platform already declares one explicitly, iOS didn't. The SFU
        // did fall back server-side to VP8 ("falling back to alternative
        // video codec" codec="video/" -> VP8), but iOS's own encoder was
        // never prepared for that fallback, so the publish then hard-timed-
        // out 30s later ("publish time out") — confirmed identical
        // client-sdk-swift source (LocalParticipant.swift, byte-for-byte)
        // between 2.13.1-aes256-raw and 2.15.1-aes256-raw, so 2.13.1 was
        // never actually safe either — it was just never exercised with an
        // unset preferredCodec in a group call before. Fixed at the call
        // site (`LiveKitGroupCallRoom.swift`'s `RoomOptions` construction,
        // `defaultVideoPublishOptions: VideoPublishOptions(preferredCodec:
        // .vp8)`), not here — restoring 2.15.1 is safe once that fix lands.
        //
        // Bumped 2026-07-28 from 2.13.1-aes256-raw to 2.15.1-aes256-raw now
        // that every CI workflow builds with Xcode 26.6 (was held at 2.13.x
        // because CI ran Xcode 15.4/Swift 5.10, and LiveKit >= 2.14.0
        // declares swift-tools-version 6.0 — see git history for that
        // superseded rationale). 2.15.1 ships `keyDerivationAlgorithm`
        // (`.pbkdf2`/`.hkdf`); this app does not set it, so it keeps the
        // same PBKDF2-unconditional behavior 2.13.0 always had — no call
        // site changes needed.
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
        // upstream) and LiveKit's `LiveKitWebRTC` (2.15.1 pins
        // webrtc-xcframework 144.7559.10) can link into the same app
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
        //
        // AES-256 fork (sigarone/client-sdk-swift, tag 2.16.0-aes256-raw4,
        // rebased from 2.15.3-aes256-raw3's same 3 commits onto upstream
        // 2.16.0 on 2026-08-21 — jumped straight past 2.15.3 same day per
        // explicit request, to not fall behind LiveKit again right before
        // this resubmission): (1) redirects the transitive
        // webrtc-xcframework dependency to
        // sigarone/webrtc-xcframework@144.7559.10-aes256-livekit (itself
        // rebuilt via sigarone/webrtc-aes256-build's build-livekit-ios.yml
        // from sigarone/webrtc@f47af7bc9658 — one day before
        // livekit/webrtc-xcframework's real 144.7559.10 cut on 2026-06-16,
        // same day-prior matching methodology already validated for
        // 144.7559.03; verified in the build log: LK-prefixed symbols
        // present, "AES-256 GCM using openssl" string present in the
        // binary), carrying the same aes256-framecryptor.patch as this
        // app's own WebRTC binaryTarget below — group-call media gets
        // AES-256-GCM instead of the fixed AES-128 FrameCryptor once a
        // 32-byte shared key is supplied (matches the Android wiring).
        // STILL pinned at 144.7559.10-aes256-livekit even though 2.16.0
        // upstream itself moved to 144.7559.11: no aes256 build of .11
        // exists yet (needs the native rebuild pipeline on a Mac — not run
        // this pass), and the checked upstream 2.15.1..2.16.0 diff touches
        // zero files under Sources/LiveKit/E2EE/ beyond the setKey(keyData:)
        // overload upstream added itself (see below), so staying one
        // WebRTC binary behind is safe for this release. (2) upstream
        // 2.16.0 added ITS OWN `setKey(keyData: Data, ...)` overload
        // (byte-identical body to the one this fork carried since
        // 2.15.1-aes256-raw) that hands the bytes VERBATIM to
        // `LKRTCFrameCryptorKeyProvider` (the String overload UTF-8-encodes,
        // so a 44-char base64 key can never fire the patched native
        // `password.size() == 32 ? 256 : 128` gate) — this rebase dropped
        // the fork's now-duplicate declaration and kept upstream's,
        // layering (3) below on top of it. `LiveKitGroupCallRoom` feeds the
        // RAW 32-byte SK_0 through this overload -> native derives
        // AES-256-GCM. (3) per-participant FrameCryptor keyIndex pinning
        // (W-GRPKEYPIN-SWIFT) — upstream did NOT pick this up on its own
        // (E2EEManager.swift unchanged 2.15.3->2.16.0), still fork-only.
        // This rebase ALSO carries upstream's own fix for Apple's
        // ITMS-90338 rejection (Guideline 2.5.1):
        // Broadcast/BroadcastManager.swift no longer calls the non-public
        // `buttonPressed:` selector (removed upstream in 2.15.3, PR #1065 /
        // commit 11a2c490, still present in 2.16.0), using public
        // `UIButton.sendActions` instead. Every other file/line in
        // client-sdk-swift 2.16.0 is untouched — same-tag-shape fork, not a
        // rewrite.
        //
        // 2026-08-26: tried bumping to raw5 (webrtc-xcframework@
        // 144.7559.10-aes256-livekit-native-pli, same native-pli.patch as the
        // direct-call WebRTC binaryTarget below) to close the group-call
        // native-PLI parity gap — REVERTED same day, stayed on raw4/
        // 144.7559.10-aes256-livekit. The native-pli rebuild of
        // LiveKitWebRTC.xcframework was MISSING `RTCAudioProcessingState.h`
        // (confirmed: downloaded both release zips and diffed the actual
        // Headers/ file listing under ios-arm64 — that one file was the only
        // difference), which client-sdk-swift's own
        // AudioProcessingModes.swift/AudioProcessingOptions.swift/
        // RTC.swift/AudioManager.swift/LocalAudioTrack.swift reference —
        // real CI compile failure (`gh run 32964484046`), not a
        // hypothetical.
        //
        // ROOT-CAUSED AND FIXED, same day: build-livekit-ios.yml's
        // `webrtc_ref` workflow_dispatch default had gone stale. It read a
        // tag pinned to a sigarone/webrtc commit dated 2026-03-30, but the
        // known-good 144.7559.10-aes256-livekit build (and every other
        // -aes256-livekit build referenced in this file's history above) was
        // actually produced by manually overriding that input to
        // f47af7bc9658-livekit-aes256-7559.10 (2026-06-15) — the YAML
        // default was never updated to match. `RTCAudioProcessingState.h`
        // does not exist anywhere in sigarone/webrtc's tree at the March
        // commit (confirmed via the GitHub Trees API, non-truncated) but
        // does exist at the June commit — genuine upstream content drift
        // between the two pins, not a build-script or patch bug; native-
        // pli.patch itself never touched this file, as suspected. Fixed at
        // the source (sigarone/webrtc-aes256-build@506c59d re-pins the
        // default to f47af7bc9658-livekit-aes256-7559.10 itself), rebuilt as
        // release tag webrtc-ios-aes256-livekit-m144-native-pli-2, and
        // VERIFIED by downloading the new zip and diffing its Headers/
        // listing against the known-good build: 112/112 files match,
        // RTCAudioProcessingState.h present — not just a green CI check.
        // webrtc-xcframework re-tagged 144.7559.10-aes256-livekit-native-
        // pli-2 (checksum b7a999c1ceb087dc818b28f9d65923e62e7d7b17bfcb8e78
        // ed497eed9e14e96e for the underlying LiveKitWebRTC.xcframework.zip)
        // and client-sdk-swift rebased onto it as 2.16.0-aes256-raw6 (raw5
        // is the broken tag above, left as-is/unused rather than reused).
        // Group-call native-PLI parity now shipped: this pin closes the gap
        // the direct-call WebRTC binaryTarget below already had.
        // 2026-09-25 (raw6 -> raw7): SECURITY rebuild, no source change. Upstream WebRTC
        // (api/crypto/frame_crypto_transformer.cc) prints the frame-cryptor secret, salt and
        // DERIVED AES key at RTC_LOG(LS_INFO); sigarone/webrtc-aes256-build's
        // no-key-log.patch removes both statements. raw7 = raw6 with the
        // webrtc-xcframework pin moved to 144.7559.10-aes256-livekit-native-pli-3 (both
        // Package.swift and Package@swift-6.2.swift), whose LiveKitWebRTC.xcframework is the
        // no-key-log rebuild (release webrtc-ios-aes256-livekit-m144-native-pli-nokeylog,
        // sha256 c03e62141d7c7989a250317e26d4c3339eb62c34429b808b77383915a76a3dfc, same WebRTC
        // commit f47af7bc9658 and same patches as -native-pli-2). Chain (lockstep, in this
        // order): webrtc-aes256-build release -> sigarone/webrtc-xcframework
        // 144.7559.10-aes256-livekit-native-pli-3 -> sigarone/client-sdk-swift 2.16.0-aes256-raw7 ->
        // here + QAudionApp/project.yml exactVersion. Rollback: raw6 (untouched tag).
        .package(url: "https://github.com/sigarone/client-sdk-swift.git", exact: "2.16.0-aes256-raw7"),
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
        // AES-256-GCM when a 32-byte K_video is set (stock binary hardcodes
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
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/sigarone/webrtc-aes256-build/releases/download/webrtc-ios-aes256-m144-native-pli-nokeylog/WebRTC.xcframework.zip",
            checksum: "7af8d47f34781d5104720faf8588162a13fe1bfabf01335fa619711c694a68cb"
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
                .copy("Crypto/Resources/handshake-sig-kat.json"),
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
                .copy("Crypto/Resources/wire_v1.0.0/ml_kem_1024/decap.json")
            ]
        )
    ]
)
