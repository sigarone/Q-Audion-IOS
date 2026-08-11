import Foundation

/// BINARY WS RELAY FRAMING v1 — hop-by-hop wire encoding for the `audio_frame`
/// relay envelope.
///
/// This is TRANSPORT FRAMING ONLY. The sealed frame handed to
/// ``encodeAudio(callId:frame:)`` is copied verbatim, byte for byte: no
/// re-padding, no re-framing, no truncation, no re-ordering. Every byte of
/// crypto is out of scope for this file, and nothing here may ever inspect the
/// payload.
///
/// Layout — fixed 18-byte header, big-endian, no length field, no flags, no
/// counters, no sender id, no timestamp, no optional fields, no padding:
///
/// ```
/// off  size  field
///  0     1   magic     0xB1 — constant. Not a legal UTF-8 leading byte, so a
///                      binary packet can never begin a valid JSON text frame.
///  1     1   ver_kind  high nibble = header version (0x1), low nibble = media
///                      kind (0x1 = audio) → 0x11. Anything else: DROP.
///  2    16   call_id   the call UUID as raw 16 bytes, RFC 4122 field order
///                      (the canonical printed order, left to right).
/// 18     N   sealed frame, verbatim.
/// ```
///
/// Because the header is fixed-size and carries nothing derived from the
/// payload, every packet of a given call is the same size — that constant-rate
/// property is the whole point, and it is why no varint, optional field or
/// length prefix may ever be added here. The header deliberately carries
/// strictly LESS than the JSON envelope did.
///
/// The parser must NOT validate `N` against any table of known profile sizes
/// (187 short / 323 long): only `total >= 19` and `total <= 32768` (the
/// server's `SetReadLimit`). Knowing which profile a packet belongs to is
/// exactly the kind of content correlation this format exists to avoid.
///
/// Video (`kind` 0x02) is reserved and MUST be rejected in phase 1:
/// `video_frame` carries `is_key_frame`, which is content-correlated.
///
/// Golden vector (cross-platform convergence point, see the contract §1):
/// `FRAME187[i] = (i*7 + 13) & 0xFF` for i in 0..<187 with call id
/// `9f8e7d6c-5b4a-4938-8271-6f5e4d3c2b1a` encodes to a 205-byte packet whose
/// SHA-256 is `6a313a1c8d4ac97b93b73f91b190dc5f2fcb55dc8615bfbaa84f156439be3531`.
public enum BinaryRelayFraming {

    /// First header byte. Chosen because 0xB1 is not a legal UTF-8 leading
    /// byte: a binary packet can never be mistaken for the start of JSON.
    public static let magic: UInt8 = 0xB1

    /// Header version, high nibble of byte 1. `bin_relay: <n>` in the
    /// negotiation and this nibble are the same number. A future layout is
    /// version 2 with `bin_relay: 2`; version 1 is never reinterpreted.
    public static let headerVersion: UInt8 = 0x1

    /// Media kind, low nibble of byte 1. Audio only in phase 1.
    public static let kindAudio: UInt8 = 0x1

    /// Reserved — video is FORBIDDEN in phase 1 and the parser must reject it.
    /// Present only so the rejection is self-documenting.
    public static let kindVideoReserved: UInt8 = 0x2

    /// The only accepted value of byte 1 in phase 1: version 1, kind audio.
    public static let verKindAudioV1: UInt8 = (headerVersion << 4) | kindAudio  // 0x11

    /// Fixed header size. Never varies, for any call, in any state.
    public static let headerLength: Int = 18

    /// Smallest legal packet: header + at least one byte of sealed frame.
    public static let minPacketLength: Int = headerLength + 1  // 19

    /// Largest legal packet — the server's existing `SetReadLimit(32768)`.
    public static let maxPacketLength: Int = 32768

    /// A successfully parsed inbound packet. Deliberately carries only what the
    /// JSON relay carried: the call id and the opaque frame. No size, no
    /// counter, no flag, no sender id.
    public struct Parsed: Equatable {
        public let callId: String
        public let frame: Data

        public init(callId: String, frame: Data) {
            self.callId = callId
            self.frame = frame
        }
    }

    // MARK: - Encode

    /// Build the outbound packet for one sealed audio frame.
    ///
    /// Returns `nil` — never a partial or "best effort" packet — when:
    ///   * `callId` does not parse to 16 bytes (contract §2.4: that call runs
    ///     on text, silently, and the id is never logged), or
    ///   * `callId` is not already in the server's canonical form (see
    ///     ``isServerCanonicalCallId(_:)``), or
    ///   * the resulting packet would fall outside `[19, 32768]`.
    ///
    /// The caller decides what a `nil` means; this type never falls back on its
    /// own and never logs.
    public static func encodeAudio(callId: String, frame: Data) -> Data? {
        // The encoder must refuse exactly what the SERVER's encoder refuses, or
        // the uplink dies silently. See ``isServerCanonicalCallId(_:)``.
        guard isServerCanonicalCallId(callId) else { return nil }
        guard let idBytes = uuidBytes(callId) else { return nil }
        let total = headerLength + frame.count
        guard total >= minPacketLength, total <= maxPacketLength else { return nil }

        var out = Data(capacity: total)
        out.append(magic)
        out.append(verKindAudioV1)
        out.append(contentsOf: idBytes)
        out.append(frame)   // verbatim, uncopied semantics — never inspected
        return out
    }

    // MARK: - Decode

    /// Strict parser. Every rejection returns `nil`; the caller drops that ONE
    /// frame and never errors the call or the socket.
    ///
    /// Rejects, in order: a packet shorter than 19 or longer than 32768 bytes;
    /// a wrong magic; any `ver_kind` other than 0x11 — which is what rejects
    /// both a future header version and the reserved video kind 0x12.
    public static func parseAudio(_ packet: Data) -> Parsed? {
        let count = packet.count
        guard count >= minPacketLength, count <= maxPacketLength else { return nil }

        // Copy into a zero-based array first: `Data` handed to us by
        // URLSession may be a slice whose `startIndex` is not 0, and
        // subscripting a slice by absolute offsets is the classic way to read
        // the wrong bytes (or trap) on exactly the frames that matter.
        let bytes = [UInt8](packet)
        guard bytes[0] == magic else { return nil }
        guard bytes[1] == verKindAudioV1 else { return nil }

        let callId = canonicalUuidString(Array(bytes[2..<headerLength]))
        let frame = Data(bytes[headerLength...])
        return Parsed(callId: callId, frame: frame)
    }

    // MARK: - UUID <-> 16 bytes

    /// The call UUID as raw bytes in RFC 4122 field order — which is exactly
    /// the canonical printed order read left to right, and exactly the byte
    /// order Foundation's `uuid_t` uses. Returns `nil` for anything Foundation
    /// will not accept as a canonical UUID string.
    static func uuidBytes(_ s: String) -> [UInt8]? {
        guard let u = UUID(uuidString: s) else { return nil }
        let t = u.uuid
        return [t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7,
                t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15]
    }

    /// True iff `callId` is the exact string the server will reconstruct from
    /// the 16 header bytes — i.e. a canonical LOWERCASE UUID.
    ///
    /// This is the one asymmetry the four-way byte-parity comparison found, and
    /// it is not cosmetic. All four codecs produce identical bytes for a given
    /// id, and all four decoders emit LOWERCASE; but only the server's encoder
    /// enforces canonicality (`binary_relay.go:150`, `id.String() != callID`),
    /// while the server's call table is keyed on the RAW wire string with no
    /// normalisation anywhere (`main.go:6869` TrackCallWithDevice →
    /// `lite_hub.go:377` `h.activeCalls[callID]`). The text relay looks the
    /// call up verbatim (`main.go:6246`); the binary relay looks it up
    /// lowercased (`binary_relay.go:303`, from `id.String()`).
    ///
    /// iOS is the platform that makes that divergence real: Foundation's
    /// `UUID().uuidString` returns UPPERCASE, and the outgoing `call_id` is
    /// minted from it (`BCryptoCallingApiImpl.swift:92`/`:538`,
    /// `Registry/CallRouter.swift:23`). So on an iOS-originated call the binary
    /// uplink misses `activeCalls`, fails `partyOK` and is answered with
    /// `call_relay_reject` and dropped — while the same frame on the text path
    /// relays fine. One-way silent audio, no error surfaced to either user:
    /// the exact failure class this design says it exists to prevent.
    ///
    /// The correct end-state fix is to normalise where the id is MINTED and in
    /// the server's table, not in the codec — but that changes the `call_id`
    /// bytes on the wire for the text path too, which invariant 1 forbids for
    /// this change. So the conservative move, and the one taken here, is to
    /// make the client refuse binary for exactly the ids the server would
    /// refuse: those calls stay on text, byte-for-byte as today, and nothing
    /// goes silently mute. The doc comment on
    /// ``canonicalUuidString(_:)`` used to assert iOS already lowercases its
    /// ids; it does not, and that claim has been corrected below.
    public static func isServerCanonicalCallId(_ callId: String) -> Bool {
        guard let u = UUID(uuidString: callId) else { return false }
        return u.uuidString.lowercased() == callId
    }

    /// Format 16 raw bytes as a canonical LOWERCASE UUID string. This is what
    /// the SERVER puts in `call_id` when it relays over the text path
    /// (`binary_relay.go:134`, `id.String()`), and what the other three
    /// decoders emit, so a call id that arrives over binary compares equal
    /// across platforms.
    ///
    /// NOTE — iOS does NOT universally mint lowercase ids: `UUID().uuidString`
    /// is uppercase and several call-origination sites use it raw. See
    /// ``isServerCanonicalCallId(_:)``.
    static func canonicalUuidString(_ b: [UInt8]) -> String {
        precondition(b.count == 16, "call id must be exactly 16 bytes")
        let u = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return u.uuidString.lowercased()
    }
}

/// Per-call wire-form latch for the relay send path.
///
/// The wire form is a property of ONE socket, never of a user and never of a
/// call — but the DECISION is taken once per call and then held, the same
/// terminal-latch discipline `CallCapabilities.resolveAudioProfile` uses for
/// the audio profile. The rules, in full (contract §2):
///
///   1. Resolve once, at the first frame of a call, from the socket's current
///      negotiated state.
///   2. If the socket dies and the replacement socket did NOT get the echo,
///      downgrade to text for the REMAINDER of that call. This is the only
///      permitted mid-call transition, and it is lossless: the peer never
///      learns which form the sender used.
///   3. NEVER upgrade mid-call. A text→binary flip would change every packet
///      size at a moment correlated with a network event.
///   4. A call id that does not parse to 16 bytes runs on text, silently. The
///      id is not stored and never logged.
///
/// Thread-safe: the relay TX tap runs on a dedicated audio queue, not main.
public final class BinaryRelayWireFormLatch: @unchecked Sendable {

    public enum WireForm: Equatable {
        case text
        case binary
    }

    /// Bound on tracked calls. A 1:1 relay call lasts minutes, so eviction is
    /// effectively unreachable in practice; the cap exists so a pathological
    /// stream of unknown call ids cannot grow this map without limit.
    public static let maxTrackedCalls: Int = 64

    private let lock = NSLock()
    private var entries: [String: WireForm] = [:]
    /// Insertion order, oldest first — used only for eviction.
    private var order: [String] = []
    /// Keys whose `.text` is TERMINAL because they were downgraded from
    /// `.binary` by rule 2, as opposed to keys that simply never became binary.
    ///
    /// The distinction exists only for eviction and it is the whole point of
    /// it: evicting a downgraded key lets the next frame re-resolve that call
    /// to `.binary`, which is the text→binary mid-call flip rule 3 forbids.
    /// `entries` alone cannot tell the two apart — both read `.text`.
    private var downgraded: Set<String> = []

    public init() {}

    /// Resolve the wire form for one outbound frame.
    ///
    /// - Parameters:
    ///   - callId: the wire `call_id` for this frame. `nil`, empty or
    ///     non-UUID ⇒ `.text`, with nothing stored and nothing logged.
    ///   - socketNegotiated: whether THIS socket received `bin_relay: 1` in its
    ///     `authenticated` payload. The only input that may make a frame
    ///     binary — no build flag alone, no server version sniff, no remote
    ///     config, no cached value from a previous socket.
    ///   - sendEnabled: the compile-time send kill switch. While it is
    ///     `false` this method is a pure function returning `.text` and writes
    ///     no state at all.
    public func resolve(callId: String?, socketNegotiated: Bool, sendEnabled: Bool) -> WireForm {
        // Compile-time kill switch first: with it off nothing is tracked, so a
        // build that ships it off behaves exactly like a build without this
        // file.
        guard sendEnabled else { return .text }
        guard let key = Self.normalizedKey(callId) else { return .text }

        lock.lock()
        defer { lock.unlock() }

        if let existing = entries[key] {
            if existing == .binary && !socketNegotiated {
                // Rule 2 — the socket was replaced and the new one did not get
                // the echo. Downgrade, terminally.
                entries[key] = .text
                // Remember WHY this key is on text, so eviction can protect it.
                // Without this the entry is indistinguishable from one that was
                // never binary, and the fallback victim search can drop it.
                downgraded.insert(key)
                return .text
            }
            // Rule 3 — a call that is on text stays on text, whatever the
            // socket now says.
            return existing
        }

        // The latch may never promise a form the encoder would then refuse, and
        // the encoder refuses exactly what the SERVER refuses — which includes
        // an id that is not canonical lowercase. iOS mints uppercase ids
        // (`UUID().uuidString`), and on those the server's binary path misses
        // its own call table and drops the uplink silently. Such a call runs on
        // text, and is latched to text so the decision is taken once.
        let encodable = BinaryRelayFraming.isServerCanonicalCallId(callId ?? "")
        let form: WireForm = (socketNegotiated && encodable) ? .binary : .text
        insert(key: key, form: form)
        return form
    }

    /// Read the latched form without resolving. Test/diagnostic only.
    public func peek(callId: String) -> WireForm? {
        guard let key = Self.normalizedKey(callId) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    /// Forget one call. Optional hygiene for a call that has ended; correctness
    /// does not depend on it being called.
    public func forget(callId: String) {
        guard let key = Self.normalizedKey(callId) else { return }
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
        downgraded.remove(key)
    }

    /// Drop every latch. Test-only: calling this during a live call would allow
    /// the forbidden mid-call upgrade.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
        downgraded.removeAll()
    }

    public var trackedCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    // MARK: - Private

    /// Caller holds `lock`.
    ///
    /// Eviction takes the oldest BINARY entry first and only falls back to the
    /// oldest entry overall when every tracked call is already on text. That
    /// ordering is not cosmetic: losing a binary entry costs nothing (the next
    /// frame re-resolves to binary on the same socket, or downgrades, both
    /// allowed), whereas losing a text entry is the one way a later frame could
    /// re-resolve to binary and produce the forbidden mid-call upgrade.
    ///
    /// Eviction runs BEFORE the insert, so the victim search can never see —
    /// and therefore never pick — the key being inserted. The previous order
    /// (append, then search) had a failure mode on a saturated map: when the
    /// incoming entry was the only `.binary` one it evicted ITSELF, so that
    /// call was never latched and re-resolved on every single frame.
    ///
    /// 2026-08-11 — the second failure mode that paragraph claimed to have
    /// closed was still open, and `testLatchEvictionKeepsDowngradedEntries` was
    /// failing on main because of it. `?? order.first` is reached whenever NO
    /// tracked entry is `.binary`, and it then evicts the oldest entry
    /// unconditionally — a downgraded one included. That is not a corner: this
    /// platform mints uppercase call ids (`UUID().uuidString`), those are not
    /// server-canonical, and [resolve] latches them to `.text` (see its own
    /// comment), so an all-text map is the ORDINARY state here rather than an
    /// exotic one. The map would saturate with text, the fallback would fire,
    /// and the one entry that must never be lost is the oldest — which a
    /// downgraded call, having been latched before the flood, tends to be.
    ///
    /// The victim search is therefore three-tiered, safest sacrifice first:
    ///   1. oldest `.binary` — free to lose; the next frame re-resolves to
    ///      `.binary` on the same socket or downgrades, and both are allowed;
    ///   2. oldest `.text` that was NEVER downgraded — re-resolving it cannot
    ///      manufacture a forbidden upgrade, because it never held the binary
    ///      state that rule 2 makes terminal;
    ///   3. only if every tracked call is a downgraded one, the oldest overall.
    /// Tier 3 is unreachable while [maxTrackedCalls] exceeds the number of
    /// concurrent calls this app can have (64 against 1), and is kept solely so
    /// this function is total rather than able to grow the map past its bound.
    private func insert(key: String, form: WireForm) {
        if entries[key] == nil, entries.count >= Self.maxTrackedCalls {
            let victim = order.first(where: { entries[$0] == .binary })
                ?? order.first(where: { !downgraded.contains($0) })
                ?? order.first
            if let victim {
                entries.removeValue(forKey: victim)
                order.removeAll { $0 == victim }
                downgraded.remove(victim)
            }
        }
        entries[key] = form
        order.append(key)
    }

    /// A call id is usable only if it parses as a canonical UUID — the same
    /// gate ``BinaryRelayFraming/encodeAudio(callId:frame:)`` applies, so the
    /// latch can never promise binary for an id the encoder would refuse.
    private static func normalizedKey(_ callId: String?) -> String? {
        guard let callId, !callId.isEmpty else { return nil }
        guard UUID(uuidString: callId) != nil else { return nil }
        return callId.lowercased()
    }
}
