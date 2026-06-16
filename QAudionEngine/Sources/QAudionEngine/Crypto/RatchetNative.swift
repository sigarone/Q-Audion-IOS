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
/// that repo's CI (`.github/workflows/ios.yml`, Stage A). Until that XCFramework is published to a
/// pinned SwiftPM `binaryTarget`, the `CQaudionCryptoCore` target links a **fail-closed placeholder
/// stub** (`qaudion_crypto_core_stub.c`): this file still compiles + type-checks against the real
/// ABI, and [available] reports `false` (so every call no-ops to its fail-closed value), exactly
/// like Android's `RatchetNative.available` is `false` when the `.so` is absent.
///
/// ## Status — DEFAULT OFF
/// This is wired but **inert** until ``MessageRatchet/v4NativeRatchetEnabled`` is flipped on AND
/// the real core is linked. Nothing in the production path calls these functions while the flag is
/// off, so the live messaging path stays the v3.1 engine (``MessageRatchet``) bit-for-bit. The v4
/// ratchet is not exercised until a device-test runs with the flag ON.
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
        guard st == QA_STATUS_OK else { return nil }
        return Data(out)
    }

    /// Open a v4 session. `root` / `firstSsXwing` / `transcriptHash` are each exactly 32 bytes;
    /// `isA` selects the "A" direction (A's send chain == B's recv chain). Returns the handle, or
    /// `0` on error. Free exactly once with ``free(_:)``.
    public static func initSession(
        root: Data, firstSsXwing: Data, transcriptHash: Data, isA: Bool
    ) -> UInt {
        guard available, root.count == 32, firstSsXwing.count == 32, transcriptHash.count == 32
        else { return 0 }
        var handle: OpaquePointer? = nil
        let st = root.withUnsafeBytesU8 { rPtr in
            firstSsXwing.withUnsafeBytesU8 { sPtr in
                transcriptHash.withUnsafeBytesU8 { tPtr in
                    qa_session_init(rPtr, sPtr, tPtr, isA ? 1 : 0, &handle)
                }
            }
        }
        guard st == QA_STATUS_OK, let h = handle else { return 0 }
        return UInt(bitPattern: Int(bitPattern: h))
    }

    /// Rebuild a session handle from a ``serialize(_:)`` buffer (app restart). Returns the new
    /// handle, or `0` (fail-closed) on a malformed/truncated buffer.
    public static func deserialize(_ data: Data) -> UInt {
        guard available else { return 0 }
        var handle: OpaquePointer? = nil
        let st = data.withUnsafeBytesU8Len { ptr, len in
            qa_session_deserialize(ptr, len, &handle)
        }
        guard st == QA_STATUS_OK, let h = handle else { return 0 }
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
                qa_ratchet_encrypt(p, ptPtr, ptLen, out, outLen)
            }
        }
    }

    /// Parse + decrypt a v4 Data wire frame; returns the plaintext, or `nil` (fail-closed) on
    /// auth/replay/parse/skip failure. No security state mutates on failure (C ABI guarantee).
    public static func decrypt(_ handle: UInt, frame: Data) -> Data? {
        guard available, handle != 0, let p = Self.pointer(handle) else { return nil }
        return queryThenFill { out, outLen in
            frame.withUnsafeBytesU8Len { fPtr, fLen in
                qa_ratchet_decrypt(p, fPtr, fLen, out, outLen)
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
        return st == QA_STATUS_OK
    }

    /// Serialize the session into the durable vault format (write-ahead / crash-resume). Returns
    /// the bytes, or `nil`.
    public static func serialize(_ handle: UInt) -> Data? {
        guard available, handle != 0, let p = Self.pointer(handle) else { return nil }
        return queryThenFill { out, outLen in
            qa_session_serialize(p, out, outLen)
        }
    }

    // MARK: - Internals

    /// Reconstitute the opaque `QaSession*` from the integer handle.
    private static func pointer(_ handle: UInt) -> OpaquePointer? {
        guard handle != 0 else { return nil }
        return OpaquePointer(bitPattern: handle)
    }

    /// Run a query-then-fill C-ABI op and return the filled bytes, or `nil` on any non-OK status.
    ///
    /// `op(out, out_len) -> QaStatus` is the raw FFI call; `out_len` is a real
    /// `UnsafeMutablePointer<Int>` (so call sites forward it straight into the C `uintptr_t *out_len`
    /// parameter — no `&` of a captured inout). We invoke it once with a 0-capacity buffer (NULL
    /// `out`, `*out_len == 0`) to learn the required size, allocate exactly that, then invoke again
    /// to fill. Mirrors the documented C-host usage and `src/android_jni.rs`'s `query_then_fill` /
    /// `tests/ffi_kat.rs::call_qtf`.
    private static func queryThenFill(
        _ op: (UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<Int>) -> Int32
    ) -> Data? {
        // 1) size query — NULL buffer, capacity 0. OK (empty output) or BufferTooSmall are valid.
        let lenPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        defer { lenPtr.deallocate() }
        lenPtr.pointee = 0
        let st = op(nil, lenPtr)
        guard st == QA_STATUS_OK || st == QA_STATUS_BUFFER_TOO_SMALL else { return nil }
        let need = lenPtr.pointee
        if need == 0 { return Data() }
        // 2) allocate + fill.
        var buf = [UInt8](repeating: 0, count: need)
        lenPtr.pointee = need
        let st2 = buf.withUnsafeMutableBufferPointer { mb -> Int32 in
            op(mb.baseAddress, lenPtr)
        }
        guard st2 == QA_STATUS_OK else { return nil }
        return Data(buf.prefix(lenPtr.pointee))
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
    func withUnsafeBytesU8Len<R>(_ body: (UnsafePointer<UInt8>?, Int) -> R) -> R {
        withUnsafeBytes { raw in body(raw.bindMemory(to: UInt8.self).baseAddress, raw.count) }
    }
}
