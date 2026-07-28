import Foundation
import CQaudionCryptoCore

/// Phase 3 (iOS) — Swift binding to the shared Rust crypto core's **v4 PQ "continuum" ratchet**
/// (`sigarone/qaudion-crypto-core`), exposed over its stable C ABI (`src/ffi.rs`).
///
/// The native side is ONE Rust implementation of the v4 ratchet state machine (clean-room SPQR;
/// ML-KEM-768 ⊕ X25519 X-Wing). The SAME engine backs Android (JNI, `src/android_jni.rs`) and
/// Desktop (N-API) — the ratchet is never hand-ported per platform, which is exactly the drift
/// risk this binding removes. iOS calls the `extern "C"` surface directly through the cbindgen
/// header (`qaudion_crypto_core.h`), imported as the `CQaudionCryptoCore` C module.
///
/// The Apple-silicon `QaudionCryptoCore.xcframework` (device + simulator static libs) is built in
/// that repo's CI (`.github/workflows/ios.yml`, Stage A) and published as a pinned SwiftPM
/// `binaryTarget` release (see `Package.swift`, `qaudion-crypto-core-spm` releases). The
/// fail-closed placeholder stub (`qaudion_crypto_core_stub.c`) only backs local builds that
/// haven't resolved that release; once resolved, [available] reports `true` exactly like Android's
/// `RatchetNative.available` does once the `.so` is present.
///
/// ## Status — DEFAULT ON (Pavel sign-off 2026-06-27)
/// ``MessageRatchet/v4NativeRatchetEnabled`` defaults to `true`; these functions are live on the
/// production path whenever the real core is linked ([available]) and the peer negotiates v4.
/// When either side lacks v4, that pair falls back to the v3.1 engine (``MessageRatchet``)
/// bit-for-bit — reversible per-pair, not a global kill switch.
///
/// ## Contract (mirrors the C ABI / `src/android_jni.rs` / `RatchetNative.kt`)
/// - The opaque native session is a `UInt` handle (the boxed `QaSession*` as an integer). `0` is
///   the canonical "no/invalid handle". A handle from ``initSession(root:firstSsXwing:transcriptHash:isA:)``
///   / ``deserialize(_:)`` MUST be released exactly once via ``free(_:)``; check ``available`` first.
/// - **Fail-closed.** Every native error collapses to `nil` (`Data?`-returning), `0`
///   (handle-returning) or `false`. No plaintext, no error oracle, no partial buffer ever crosses
///   the boundary — AEAD/auth/replay/parse failures are indistinguishable to the caller, identical
///   to the C ABI posture.
/// - **Threading.** A handle is single-threaded (native `&mut self` semantics): do not use one
///   handle from two threads concurrently. This binding adds no locking (same as the C ABI).
/// - All 32-byte inputs (root / X-Wing secret / transcript hash) must be exactly 32 bytes; a wrong
///   length yields a fail-closed result, never a crash.
public enum RatchetNative {

    /// True iff the REAL crypto core is linked (not the fail-closed placeholder stub). Detected via
    /// `qa_version()`: the stub returns `0`, the real core returns a non-zero packed semver
    /// (`0.1.0` -> `0x0001_0000`). Mirrors Android's `RatchetNative.available` (which is driven by
    /// `System.loadLibrary` succeeding). A caller should branch on this before any other call; when
    /// `false`, every method here fail-closes.
    public static let available: Bool = qa_version() != 0

    /// ABI/semver of the linked core as `(major<<16)|(minor<<8)|patch`, or `0` if only the stub is
    /// linked. Lets a caller assert it linked the expected core (`0.1.0` -> `0x0001_0000` = 65536).
    public static func version() -> UInt32 { qa_version() }

    // MARK: - Session lifecycle

    /// Derive `ROOT_0 = HKDF-SHA384(ssHandshake, "qa/v4/root-init")` from a 32-byte handshake
    /// shared secret. Returns the 32-byte root, or `nil` (wrong length / unavailable / error).
    public static func root0(ssHandshake: Data) -> Data? {
        guard available, ssHandshake.count == 32 else { return nil }
        var out = [UInt8](repeating: 0, count: 32)
        let st = ssHandshake.withUnsafeBytesU8 { inPtr in
            qa_root_0(inPtr, &out)
        }
        guard qaStatusCode(st) == 0 else { return nil }
        return Data(out)
    }

    /// Bootstrap a v4 session (Model A, §4.1). `root` (ROOT_0) / `transcriptHash` are 32 bytes;
    /// `sessionEpochId` is 16 bytes (the lex-min party's epoch_id, §2.5). `isLexMin` selects this
    /// party's direction. Epoch-1 chains derive directly from ROOT_0 — NO X-Wing at bootstrap.
    /// Returns the handle, or `0` on error. Free exactly once with ``free(_:)``.
    public static func initSession(
        root: Data, sessionEpochId: Data, transcriptHash: Data, isLexMin: Bool
    ) -> UInt {
        guard available, root.count == 32, sessionEpochId.count == 16, transcriptHash.count == 32
        else { return 0 }
        var handle: OpaquePointer?
        let st = root.withUnsafeBytesU8 { rPtr in
            sessionEpochId.withUnsafeBytesU8 { sPtr in
                transcriptHash.withUnsafeBytesU8 { tPtr in
                    qa_session_init(rPtr, sPtr, tPtr, isLexMin ? 1 : 0, &handle)
                }
            }
        }
        guard qaStatusCode(st) == 0, let h = handle else { return 0 }
        return UInt(bitPattern: Int(bitPattern: h))
    }

    /// Bootstrap a v4 session directly from the Phase-10b handshake outputs (Model A §4.1 + §2.5),
    /// mirroring Android `MessageRatchet.bootstrapV4`. Derives `ROOT_0 = root0(effectiveSecret)`,
    /// the lex-order from the long-term identity public keys (unsigned-byte compare; lex-min =
    /// lexicographically smaller), and `session_epoch_id` = the lex-min party's 16-byte `epochId`.
    /// `selfEpochId` / `peerEpochId` are the per-direction epoch_ids from the signed handshake
    /// transcript. Returns the handle, or `0` (disabled / malformed input).
    public static func bootstrapV4(
        effectiveSecret: Data, selfEpochId: Data, peerEpochId: Data,
        selfIdentityPub: Data, peerIdentityPub: Data, transcriptHash: Data
    ) -> UInt {
        guard available, selfEpochId.count == 16, peerEpochId.count == 16,
              let root0 = root0(ssHandshake: effectiveSecret) else { return 0 }
        let isLexMin = lexLessBytes([UInt8](selfIdentityPub), [UInt8](peerIdentityPub))
        let sessionEpochId = isLexMin ? selfEpochId : peerEpochId
        return initSession(root: root0, sessionEpochId: sessionEpochId,
                           transcriptHash: transcriptHash, isLexMin: isLexMin)
    }

    /// §2.5 lex-order on long-term identity public keys: unsigned-byte compare, `true` iff a < b.
    private static func lexLessBytes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let lim = min(a.count, b.count)
        var i = 0
        while i < lim {
            if a[i] != b[i] { return a[i] < b[i] }
            i += 1
        }
        return a.count < b.count
    }

    /// Rebuild a session handle from a ``serialize(_:)`` buffer (app restart). Returns the new
    /// handle, or `0` (fail-closed) on a malformed/truncated buffer.
    public static func deserialize(_ data: Data) -> UInt {
        guard available else { return 0 }
        var handle: OpaquePointer?
        let st = data.withUnsafeBytesU8Len { ptr, len in
            qa_session_deserialize(ptr, len, &handle)
        }
        guard qaStatusCode(st) == 0, let h = handle else { return 0 }
        return UInt(bitPattern: Int(bitPattern: h))
    }

    /// Release a session handle. Safe with `0` (no-op). MUST be called exactly once per handle
    /// returned by ``initSession(root:firstSsXwing:transcriptHash:isA:)`` / ``deserialize(_:)``.
    public static func free(_ handle: UInt) {
        guard available, handle != 0, let p = Self.pointer(handle) else { return }
        qa_session_free(p)
    }

    // MARK: - Ratchet operations

    /// Encrypt on the send chain; returns the v4 Data wire frame (magic `0xE5`), or `nil`. Advances
    /// the send chain on success — per the write-ahead contract the caller MUST ``serialize(_:)`` +
    /// persist BEFORE transmitting the returned frame.
    public static func encrypt(_ handle: UInt, plaintext: Data) -> Data? {
        guard available, handle != 0, let p = Self.pointer(handle) else { return nil }
        return queryThenFill { out, outLen in
            plaintext.withUnsafeBytesU8Len { ptPtr, ptLen in
                qaStatusCode(qa_ratchet_encrypt(p, ptPtr, ptLen, out, outLen))
            }
        }
    }

    /// Parse + decrypt a v4 Data wire frame; returns the plaintext, or `nil` (fail-closed) on
    /// auth/replay/parse/skip failure. No security state mutates on failure (C ABI guarantee).
    public static func decrypt(_ handle: UInt, frame: Data) -> Data? {
        guard available, handle != 0, let p = Self.pointer(handle) else { return nil }
        return queryThenFill { out, outLen in
            frame.withUnsafeBytesU8Len { fPtr, fLen in
                qaStatusCode(qa_ratchet_decrypt(p, fPtr, fLen, out, outLen))
            }
        }
    }

    /// Advance into the next epoch with a fresh 32-byte X-Wing secret + 32-byte transcript hash
    /// (both peers call with identical inputs). `true` on success, `false` on any error.
    public static func dhRatchet(_ handle: UInt, ssXwing: Data, transcriptHash: Data) -> Bool {
        guard available, handle != 0, let p = Self.pointer(handle),
              ssXwing.count == 32, transcriptHash.count == 32 else { return false }
        let st = ssXwing.withUnsafeBytesU8 { sPtr in
            transcriptHash.withUnsafeBytesU8 { tPtr in
                qa_dh_ratchet(p, sPtr, tPtr)
            }
        }
        return qaStatusCode(st) == 0
    }

    /// Serialize the session into the durable vault format (write-ahead / crash-resume). Returns
    /// the bytes, or `nil`.
    public static func serialize(_ handle: UInt) -> Data? {
        guard available, handle != 0, let p = Self.pointer(handle) else { return nil }
        return queryThenFill { out, outLen in
            qaStatusCode(qa_session_serialize(p, out, outLen))
        }
    }

    // MARK: - File encryption (Phase 4)

    /// Encrypt `plaintext` as a standalone file blob keyed from the session root + `fileId`.
    ///
    /// Returns `ciphertext ‖ tag` (`plaintext.count + 16` bytes), or `nil` on error. Does NOT
    /// advance the ratchet chain — the session root provides the key material (stable within an
    /// epoch). `counter` is the AES-GCM nonce counter; use `0` for a single-chunk file.
    ///
    /// Key derivation: `HKDF-SHA256(root, info="qa/v4/file/"‖fileId, L=32)`. Both peers derive the
    /// same key given the same `fileId` — no extra coordination required.
    public static func fileEncrypt(_ handle: UInt, fileId: Data, plaintext: Data, counter: UInt64 = 0) -> Data? {
        guard available, handle != 0, let p = Self.pointer(handle) else { return nil }
        return queryThenFill { out, outLen in
            fileId.withUnsafeBytesU8Len { fidPtr, fidLen in
                plaintext.withUnsafeBytesU8Len { ptPtr, ptLen in
                    qaStatusCode(qa_file_encrypt(p, fidPtr, fidLen, ptPtr, ptLen, counter, out, outLen))
                }
            }
        }
    }

    /// Decrypt a ``fileEncrypt(_:fileId:plaintext:counter:)`` blob. `ctTag` is `ciphertext ‖ tag`.
    /// Returns the plaintext, or `nil` (fail-closed) on any auth/parse error. Does NOT advance the
    /// ratchet chain.
    public static func fileDecrypt(_ handle: UInt, fileId: Data, ctTag: Data, counter: UInt64 = 0) -> Data? {
        guard available, handle != 0, let p = Self.pointer(handle) else { return nil }
        return queryThenFill { out, outLen in
            fileId.withUnsafeBytesU8Len { fidPtr, fidLen in
                ctTag.withUnsafeBytesU8Len { ctPtr, ctLen in
                    qaStatusCode(qa_file_decrypt(p, fidPtr, fidLen, ctPtr, ctLen, counter, out, outLen))
                }
            }
        }
    }

    /// Derive the 32-byte media session secret for a call.
    /// `HKDF-SHA256(root, "qa/v4/media/"‖callId, L=32)`. Read-only — no ratchet chain mutates.
    public static func mediaKey(_ handle: UInt, callId: Data) -> Data? {
        guard available, handle != 0, let p = Self.pointer(handle) else { return nil }
        return queryThenFill { out, outLen in
            callId.withUnsafeBytesU8Len { cidPtr, cidLen in
                qaStatusCode(qa_media_key(p, cidPtr, cidLen, out, outLen))
            }
        }
    }

    // MARK: - Advance braid (X-Wing dh_ratchet, ratchet_gen >= 1)
    //
    // Bootstrap needs no braid (Model A, epoch-1 = ROOT_0-direct). The braid derives the 32-byte
    // SS_xwing both peers feed to ``dhRatchet(_:ssXwing:transcriptHash:)``; the caller applies
    // dhRatchet itself. ``braidResponderOffer`` is progress-oblivious — poll ``braidResponderIsReady``.

    /// Encapsulate against the peer's published per-advance ephemeral ratchet pubkeys. Returns the
    /// initiator handle, or `0` on error. Free via ``braidInitiatorFree(_:)``.
    public static func braidInitiate(
        peerMlkemPk: Data, peerX25519Pk: Data, mlkemSeed: Data, x25519Seed: Data,
        ratchetGen: UInt32, callId: Data
    ) -> UInt {
        guard available, peerMlkemPk.count == 1184, peerX25519Pk.count == 32,
              mlkemSeed.count == 32, x25519Seed.count == 32, callId.count == 16 else { return 0 }
        var handle: OpaquePointer?
        let st = peerMlkemPk.withUnsafeBytesU8 { pk in
            peerX25519Pk.withUnsafeBytesU8 { xpk in
                mlkemSeed.withUnsafeBytesU8 { ms in
                    x25519Seed.withUnsafeBytesU8 { xs in
                        callId.withUnsafeBytesU8 { cid in
                            qa_braid_initiate(pk, xpk, ms, xs, ratchetGen, cid, &handle)
                        }
                    }
                }
            }
        }
        guard qaStatusCode(st) == 0, let h = handle else { return 0 }
        return UInt(bitPattern: Int(bitPattern: h))
    }

    /// The flattened shard frames to transmit, or `nil`.
    public static func braidInitiatorFrames(_ handle: UInt) -> Data? {
        guard available, handle != 0, let p = Self.pointer(handle) else { return nil }
        return queryThenFill { out, outLen in qaStatusCode(qa_braid_initiator_frames(p, out, outLen)) }
    }

    /// The 32-byte SS_xwing to feed to ``dhRatchet(_:ssXwing:transcriptHash:)``, or `nil`.
    public static func braidInitiatorSecret(_ handle: UInt) -> Data? {
        guard available, handle != 0, let p = Self.pointer(handle) else { return nil }
        return braidSecret { out32 in qaStatusCode(qa_braid_initiator_secret(p, out32)) }
    }

    /// Free an initiator braid handle (no-op on `0`).
    public static func braidInitiatorFree(_ handle: UInt) {
        guard available, handle != 0, let p = Self.pointer(handle) else { return }
        qa_braid_initiator_free(p)
    }

    /// Responder accumulator holding this party's per-advance ephemeral ratchet privates. `0` on error.
    public static func braidResponderNew(
        ratchetGen: UInt32, callId: Data, mlkemSk: Data, x25519Secret: Data, x25519Pub: Data
    ) -> UInt {
        guard available, callId.count == 16, mlkemSk.count == 2400,
              x25519Secret.count == 32, x25519Pub.count == 32 else { return 0 }
        var handle: OpaquePointer?
        let st = callId.withUnsafeBytesU8 { cid in
            mlkemSk.withUnsafeBytesU8 { sk in
                x25519Secret.withUnsafeBytesU8 { xsec in
                    x25519Pub.withUnsafeBytesU8 { xpub in
                        qa_braid_responder_new(ratchetGen, cid, sk, xsec, xpub, &handle)
                    }
                }
            }
        }
        guard qaStatusCode(st) == 0, let h = handle else { return 0 }
        return UInt(bitPattern: Int(bitPattern: h))
    }

    /// Absorb one received frame (progress-oblivious). `false` only on an invalid handle.
    public static func braidResponderOffer(_ handle: UInt, frame: Data) -> Bool {
        guard available, handle != 0, let p = Self.pointer(handle) else { return false }
        let st = frame.withUnsafeBytesU8Len { fPtr, fLen in
            qaStatusCode(qa_braid_responder_offer(p, fPtr, fLen))
        }
        return st == 0
    }

    /// `true` once `>= RS_K` shards are collected.
    public static func braidResponderIsReady(_ handle: UInt) -> Bool {
        guard available, handle != 0, let p = Self.pointer(handle) else { return false }
        return qa_braid_responder_is_ready(p) == 1
    }

    /// Reconstruct + decapsulate → the 32-byte SS_xwing to feed to dhRatchet, or `nil`.
    public static func braidResponderSecret(_ handle: UInt) -> Data? {
        guard available, handle != 0, let p = Self.pointer(handle) else { return nil }
        return braidSecret { out32 in qaStatusCode(qa_braid_responder_secret(p, out32)) }
    }

    /// Free a responder braid handle (no-op on `0`).
    public static func braidResponderFree(_ handle: UInt) {
        guard available, handle != 0, let p = Self.pointer(handle) else { return }
        qa_braid_responder_free(p)
    }

    // MARK: - Internals

    /// Read a fixed 32-byte secret out-param (the SS_xwing). `op(out32) -> QaStatus`; `nil` on error.
    private static func braidSecret(_ op: (UnsafeMutablePointer<UInt8>) -> Int32) -> Data? {
        var out = [UInt8](repeating: 0, count: 32)
        // force-unwrap safe: out is a fixed 32-byte array, always non-empty —
        // baseAddress is only nil for an empty buffer.
        // swiftlint:disable:next force_unwrapping
        let st = out.withUnsafeMutableBufferPointer { mb -> Int32 in op(mb.baseAddress!) }
        guard st == 0 else { return nil }
        return Data(out)
    }

    /// Reconstitute the opaque `QaSession*` / braid handle from the integer handle.
    private static func pointer(_ handle: UInt) -> OpaquePointer? {
        guard handle != 0 else { return nil }
        return OpaquePointer(bitPattern: handle)
    }

    /// Run a query-then-fill C-ABI op and return the filled bytes, or `nil` on any non-OK status.
    ///
    /// `op(out, out_len) -> QaStatus` is the raw FFI call; `out_len` is a real
    /// `UnsafeMutablePointer<UInt>` (maps to the C `uintptr_t *out_len` parameter directly
    /// — no `&` of a captured inout). We invoke it once with a 0-capacity buffer (NULL
    /// `out`, `*out_len == 0`) to learn the required size, allocate exactly that, then invoke again
    /// to fill. Mirrors the documented C-host usage and `src/android_jni.rs`'s `query_then_fill` /
    /// `tests/ffi_kat.rs::call_qtf`.
    // Reads the raw Int32 from a QaStatus value regardless of how Swift's Clang importer
    // resolves the mixed enum-typedef in qaudion_crypto_core.h.
    // On macOS (swift test): QaStatus == Int32 (typedef wins).
    // On iOS Simulator (xcodebuild): the enum and the typedef are BOTH exported as
    // distinct `CQaudionCryptoCore.QaStatus` candidates — writing `QaStatus` in a Swift
    // type annotation is ambiguous. Using a generic parameter avoids any annotation while
    // still reading the 4 raw bytes correctly in both cases.
    @inline(__always)
    private static func qaStatusCode<T>(_ s: T) -> Int32 {
        var v = s
        return withUnsafeMutableBytes(of: &v) { $0.load(as: Int32.self) }
    }

    // `op` returns Int32 so no QaStatus type annotation is needed here.
    // Call sites wrap the C function result with qaStatusCode() before passing.
    private static func queryThenFill(
        _ op: (UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt>) -> Int32
    ) -> Data? {
        // 1) size query — NULL buffer, capacity 0. OK (empty output) or BufferTooSmall are valid.
        let lenPtr = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
        defer { lenPtr.deallocate() }
        lenPtr.pointee = 0
        let st = op(nil, lenPtr)
        guard st == 0 || st == -2 else { return nil }
        let need = Int(lenPtr.pointee)
        if need == 0 { return Data() }
        // 2) allocate + fill.
        var buf = [UInt8](repeating: 0, count: need)
        lenPtr.pointee = UInt(need)
        let st2 = buf.withUnsafeMutableBufferPointer { mb -> Int32 in
            op(mb.baseAddress, lenPtr)
        }
        guard st2 == 0 else { return nil }
        return Data(buf.prefix(Int(lenPtr.pointee)))
    }
}

// MARK: - Data → C pointer helpers (keep the call sites readable above)

private extension Data {
    /// Pass the bytes as a `const uint8_t *`. For an empty `Data` the pointer may be NULL, which is
    /// fine for the 32-byte-input paths (guarded by an explicit `count == 32` check before use).
    func withUnsafeBytesU8<R>(_ body: (UnsafePointer<UInt8>?) -> R) -> R {
        withUnsafeBytes { raw in body(raw.bindMemory(to: UInt8.self).baseAddress) }
    }

    /// Pass the bytes as `(const uint8_t *, uintptr_t)`. An empty `Data` yields `(NULL, 0)` — the C
    /// ABI accepts a NULL pointer when the length is 0 (empty plaintext / empty frame is rejected
    /// downstream as a parse error, fail-closed).
    func withUnsafeBytesU8Len<R>(_ body: (UnsafePointer<UInt8>?, UInt) -> R) -> R {
        withUnsafeBytes { raw in body(raw.bindMemory(to: UInt8.self).baseAddress, UInt(raw.count)) }
    }
}
