import Foundation

/// Drop-in SFrame sealer for the iOS video pipeline — Swift mirror of the
/// Android `SFrameVideoSealer.kt` contract.
///
/// **Wire format:** each call to ``seal(plaintext:layer:keyFrame:padded:)``
/// returns one SFrame frame as specified in `docs/SFRAME_VIDEO_WIRE_SPEC.md`:
/// ```
///   cfg(1) [|ext(1)] | KID(0..3) | CTR(1..8) | ciphertext | tag(16)
/// ```
///
/// **Rekey transparency (validated by OpenRouter Gemini-2.5-pro and NVIDIA
/// Llama-3.3-70b — both picked Option A: per-frame HKDF derivation):** the
/// SFrame master is NOT cached at construction time; it is re-derived from
/// the input key material on every ``seal(plaintext:layer:keyFrame:padded:)``
/// / ``open(_:)`` call via `masterProvider`. When the audio-driven
/// `ReKeyScheduler` rotates the underlying PQC session key mid-call, the
/// next outbound video frame automatically picks up the new master without
/// any controller-side reconstruction. Cost: 2 HKDF-SHA256 expansions per
/// frame (~3-4 µs on A14+; ~100 µs/sec at 30 fps — negligible).
///
/// **Counter management.** The CTR is monotonic per sealer instance,
/// guarded by an `NSLock` (we have no swift-atomics dependency in the
/// engine package). Layer mux is handled inside ``SFrameCodec/seal(master:ctr:plaintext:kid:layer:padded:keyFrame:)``
/// (top 4 bits of CTR). On rekey the CTR keeps advancing — there is no
/// `(key, nonce)` collision risk because the master itself changes
/// deterministically with the new input key (HKDF gives a fresh
/// frame-salt as well).
public final class SFrameVideoSealer: @unchecked Sendable {

    public static let nonceSize = SFrameCodec.nonceSize
    public static let tagSize = SFrameCodec.tagSize

    private let masterProvider: () -> Data
    private let kid: Data

    private let counterLock = NSLock()
    private var counter: UInt64 = 0

    private init(masterProvider: @escaping () -> Data, kid: Data) {
        self.masterProvider = masterProvider
        self.kid = kid
    }

    /// Seal one fragment. The caller is expected to have already encoded
    /// and fragmented the source frame — input here is the per-fragment
    /// plaintext (≤ ~1200 B for typical RTP MTU).
    ///
    /// The simulcast layer is set per-frame; for 1:1 calls (no simulcast)
    /// the default `.mid` mirrors the Kotlin contract.
    public func seal(
        plaintext: Data,
        layer: SFrameCodec.Layer = .mid,
        keyFrame: Bool = false,
        padded: Bool = false
    ) throws -> Data {
        let ctr = nextCounter()
        let master = masterProvider()
        return try SFrameCodec.seal(
            master: master,
            ctr: ctr,
            plaintext: plaintext,
            kid: kid,
            layer: layer,
            padded: padded,
            keyFrame: keyFrame
        )
    }

    /// Open a sealed frame. Master is freshly derived per-call so peer
    /// rekeys are picked up without controller-side restart.
    ///
    /// Throws on tag mismatch (wrong key, tampered AAD or ciphertext) —
    /// callers should treat this as a dropped frame and continue.
    public func open(_ wire: Data) throws -> Data {
        return try SFrameCodec.open(master: masterProvider(), wire: wire)
    }

    /// Expose the current counter for telemetry / debug logging only.
    /// Do NOT use this to derive nonces or other crypto material — the
    /// codec already handles that.
    public func counterSnapshot() -> UInt64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        return counter
    }

    private func nextCounter() -> UInt64 {
        counterLock.lock()
        let v = counter
        counter &+= 1
        counterLock.unlock()
        return v
    }

    // MARK: - Factories

    /// Build a sealer for a 1:1 call against a STATIC PQC session key.
    /// Used by tests and any caller that knows the key won't rotate
    /// during the sealer's lifetime.
    ///
    /// For a live call where the audio rekey scheduler rotates the
    /// session key mid-call, prefer ``forRotatingKey(_:)`` which
    /// re-derives the master from the current key on every frame.
    ///
    /// - Precondition: `pqcSessionKey.count == 32`.
    public static func forOneToOne(pqcSessionKey: Data) -> SFrameVideoSealer {
        precondition(pqcSessionKey.count == 32, "pqcSessionKey must be 32 bytes")
        let frozen = Data(pqcSessionKey) // defensive copy
        return SFrameVideoSealer(
            masterProvider: {
                // Length already checked above; force-try is safe.
                return try! SFrameCodec.deriveMaster1to1(frozen)
            },
            kid: Data()
        )
    }

    /// Build a sealer that re-derives its SFrame master from a rotating
    /// PQC session key on every seal/open.
    ///
    /// - Parameter pqcKeyProvider: returns the current 32-byte session
    ///   key. Typically backed by a CallController-held `var activeKey`
    ///   or an `OSAllocatedUnfairLock`-guarded reference. Must NOT
    ///   throw; if the key isn't yet available the caller should defer
    ///   sealer construction. The provider's return value is validated
    ///   on every call — a non-32-byte return triggers a precondition
    ///   failure (mirrors Kotlin's `IllegalArgumentException`).
    public static func forRotatingKey(_ pqcKeyProvider: @escaping () -> Data) -> SFrameVideoSealer {
        return SFrameVideoSealer(
            masterProvider: {
                let k = pqcKeyProvider()
                precondition(k.count == 32, "pqcKeyProvider returned a key of size \(k.count), expected 32")
                return try! SFrameCodec.deriveMaster1to1(k)
            },
            kid: Data()
        )
    }

    /// Build a sealer for one sender in a group call. The master is
    /// derived from the per-sender chain key produced by the existing
    /// `GroupSenderKey` ratchet via
    /// ``SFrameCodec/deriveMasterGroup(chainKey:groupIdHex:senderId:)``.
    /// `kid` is the 24-bit truncated SHA-256 of the sender id (provided
    /// by the caller; the codec does not compute it for you).
    ///
    /// Static-chain-key variant — used by tests. For a live group call
    /// where the ratchet advances mid-frame, prefer
    /// ``forGroupRotating(chainKeyProvider:groupIdHex:senderId:kid:)``.
    ///
    /// - Precondition: `kid.count == 3` and `chainKey.count == 32`.
    public static func forGroup(
        chainKey: Data,
        groupIdHex: String,
        senderId: String,
        kid: Data
    ) -> SFrameVideoSealer {
        precondition(kid.count == 3, "group KID must be exactly 3 bytes (24-bit truncated SHA-256)")
        precondition(chainKey.count == 32, "chainKey must be 32 bytes")
        let frozen = Data(chainKey)
        let kidCopy = Data(kid)
        return SFrameVideoSealer(
            masterProvider: {
                return try! SFrameCodec.deriveMasterGroup(
                    chainKey: frozen,
                    groupIdHex: groupIdHex,
                    senderId: senderId
                )
            },
            kid: kidCopy
        )
    }

    /// Group-call sealer with a rotating chain-key provider — picks up
    /// `GroupSenderKey` ratchet steps and group-epoch advances
    /// automatically.
    ///
    /// - Precondition: `kid.count == 3`. The provider's return value is
    ///   validated on every call — a non-32-byte return triggers a
    ///   precondition failure.
    public static func forGroupRotating(
        chainKeyProvider: @escaping () -> Data,
        groupIdHex: String,
        senderId: String,
        kid: Data
    ) -> SFrameVideoSealer {
        precondition(kid.count == 3, "group KID must be exactly 3 bytes (24-bit truncated SHA-256)")
        let kidCopy = Data(kid)
        return SFrameVideoSealer(
            masterProvider: {
                let ck = chainKeyProvider()
                precondition(ck.count == 32, "chainKeyProvider returned key of size \(ck.count), expected 32")
                return try! SFrameCodec.deriveMasterGroup(
                    chainKey: ck,
                    groupIdHex: groupIdHex,
                    senderId: senderId
                )
            },
            kid: kidCopy
        )
    }
}
