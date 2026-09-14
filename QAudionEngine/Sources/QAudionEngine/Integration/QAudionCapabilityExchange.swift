import Foundation

/// Capability exchange protocol matching Android `QAudionCapabilityExchange.kt` binary format EXACTLY.
///
/// Android wire format (authoritative):
///   [4B MAGIC "QUAD"][1B type][1B version][1B features][2B pubKeyLen BE][pubKey][2B kemLen BE][kemCiphertext][PSK fps]
///
/// PSK fingerprint section:
///   [2B fpCount BE][for each: 2B fpLen BE + UTF-8 fingerprint bytes]
///
/// Header size: 4 (magic) + 1 (type) + 1 (version) + 1 (features) + 2 (pubKeyLen) + 2 (kemLen) = 11 bytes minimum.
public enum QAudionCapabilityExchange {

    // MARK: - Constants (match Android exactly)
    private static let magic: [UInt8] = [0x51, 0x41, 0x55, 0x44]  // "QUAD"
    private static let protocolVersion: UInt8 = 0x01

    // Feature flags (1 byte bitfield, matches Android)
    public static let featurePQC: UInt8        = 0x01  // ML-KEM-1024 support (mandatory)
    public static let featureOpusCBR: UInt8    = 0x02  // Opus CBR anti-traffic-analysis
    public static let featureDeepfake: UInt8   = 0x04  // GuardianMode deepfake detection
    public static let featurePSK: UInt8        = 0x08  // Pre-shared key available
    public static let featureDualCurve: UInt8  = 0x10  // X25519 + X448 (RFC 7748)

    /// Default features advertised by this iOS client.
    public static let defaultFeatures: UInt8 = featurePQC | featureDeepfake | featurePSK

    /// Opcodes aligned with Q-Audion Desktop / Android wire protocol.
    /// Note: 0x03/0x04/0x05 were renumbered on iOS to match Desktop; AUDIO_DATA moved
    /// from 0x03 → 0x06 and VOICE_ANALYSIS moved from 0x04 → 0x07. See
    /// qaudion-desktop/docs/IOS_INTEROP_GAP.md.
    public enum MessageType: UInt8 {
        case offer = 0x01
        case accept = 0x02
        case dcSdpOffer = 0x03          // was audioData on iOS
        case dcSdpAnswer = 0x04         // was voiceAnalysis on iOS
        case dcIce = 0x05               // was dcSdpOffer on iOS
        case audioData = 0x06           // moved from 0x03
        case voiceAnalysis = 0x07       // moved from 0x04
        case callHangup = 0x08          // new
        case keyExchangeOffer = 0x09    // new (no handler yet — enum stub for Desktop/Android interop)
        case keyExchangeAccept = 0x0a   // new (no handler yet — enum stub for Desktop/Android interop)
    }

    public enum Message {
        case offer(publicKey: Data, features: UInt8, pskFingerprints: [String])
        case accept(ciphertext: Data, pskFingerprint: String?)
        /// W-GRPFALLBACKAUDIO-IOS (2026-08-27) — carries EVERY sealed frame
        /// batched into this envelope by `createAudioData(frames:)`, not just
        /// the first one. Before this fix, `parseBinary`'s `.audioData` case
        /// returned the WHOLE multi-frame payload (2B frameCount header +
        /// [2B len + frame] * N) as if it were a single opaque `frame: Data`
        /// — a caller feeding that straight into an AEAD `open()` would fail
        /// every single time (the count/length headers corrupt the
        /// ciphertext), and nothing in this file exercised the round trip
        /// end-to-end before now to catch it (`QAudionCapabilityExchangeTests`
        /// only covered offer/accept). Never shipped to any call site — this
        /// message type had zero application-layer callers on iOS until the
        /// group-call SFU-outage fallback-audio receive path.
        case audioData(frames: [Data])
        case voiceAnalysis(data: Data)
        case dcSdpOffer(sdp: String)
        case dcSdpAnswer(sdp: String)
        case dcIce(candidate: String)
        case callHangup(reason: String)
        case keyExchangeOffer(payload: Data)
        case keyExchangeAccept(payload: Data)
    }

    // MARK: - Serialize (Android-compatible binary format)

    /// Creates an OFFER message matching Android format exactly.
    /// Header: [MAGIC][TYPE=0x01][VERSION=0x01][FEATURES][pubKeyLen BE][pubKey][kemLen=0 BE]
    /// Followed by PSK fingerprints: [fpCount 2B BE][fpLen 2B BE + UTF-8 data]...
    public static func createOffer(
        publicKey: Data,
        features: UInt8 = defaultFeatures,
        kemCiphertext: Data? = nil,
        pskFingerprints: [String] = []
    ) -> Data {
        var data = Data()

        // Header (matches Android serialize() exactly)
        data.append(contentsOf: magic)                              // 4B: "QUAD"
        data.append(MessageType.offer.rawValue)                     // 1B: type
        data.append(protocolVersion)                                // 1B: version
        data.append(features)                                       // 1B: features

        // Public key
        appendUInt16BE(&data, UInt16(publicKey.count))              // 2B: pubKeyLen
        data.append(publicKey)                                       // NB: pubKey

        // KEM ciphertext (0 if absent)
        let kemLen = kemCiphertext?.count ?? 0
        appendUInt16BE(&data, UInt16(kemLen))                       // 2B: kemLen
        if let kem = kemCiphertext {
            data.append(kem)
        }

        // PSK fingerprints (appended after KEM, 2B count + 2B len per fp)
        if !pskFingerprints.isEmpty {
            appendUInt16BE(&data, UInt16(pskFingerprints.count))    // 2B: fpCount
            for fp in pskFingerprints {
                let fpData = Data(fp.utf8)
                appendUInt16BE(&data, UInt16(fpData.count))         // 2B: fpLen
                data.append(fpData)                                  // NB: fpData
            }
        }

        return data
    }

    /// Creates an ACCEPT message.
    public static func createAccept(
        ciphertext: Data,
        features: UInt8 = defaultFeatures,
        pskFingerprint: String? = nil
    ) -> Data {
        var data = Data()
        data.append(contentsOf: magic)
        data.append(MessageType.accept.rawValue)
        data.append(protocolVersion)
        data.append(features)

        // Public key slot (empty for ACCEPT — ciphertext goes here instead)
        appendUInt16BE(&data, UInt16(0))

        // KEM ciphertext
        appendUInt16BE(&data, UInt16(ciphertext.count))
        data.append(ciphertext)

        // Selected PSK fingerprint
        if let fp = pskFingerprint {
            let fpData = Data(fp.utf8)
            appendUInt16BE(&data, UInt16(1))  // count = 1
            appendUInt16BE(&data, UInt16(fpData.count))
            data.append(fpData)
        }

        return data
    }

    /// Creates an AUDIO_DATA message wrapping encrypted frames.
    public static func createAudioData(frames: [Data]) -> Data {
        var payload = Data()
        appendUInt16BE(&payload, UInt16(frames.count))
        for frame in frames {
            appendUInt16BE(&payload, UInt16(frame.count))
            payload.append(frame)
        }
        return wrapSimpleMessage(type: .audioData, payload: payload)
    }

    /// Reverse of `createAudioData(frames:)`'s batch layout:
    /// `[2B frameCount BE][for each: 2B frameLen BE + frame bytes]`.
    /// Returns `nil` on any truncation/overrun rather than throwing — mirrors
    /// this file's existing `parseBinary` posture (malformed wire input is a
    /// silent drop, never a crash).
    static func parseAudioDataBatch(_ payload: Data) -> [Data]? {
        guard payload.count >= 2 else { return nil }
        let base = payload.startIndex
        let count = Int(readUInt16BE(payload, offset: base))
        var offset = base + 2
        var frames: [Data] = []
        frames.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 2 <= payload.endIndex else { return nil }
            let len = Int(readUInt16BE(payload, offset: offset))
            offset += 2
            guard offset + len <= payload.endIndex else { return nil }
            frames.append(Data(payload[offset..<(offset + len)]))
            offset += len
        }
        return frames
    }

    /// Cheap magic-byte sniff so a receive path that shares a channel with
    /// another wire format (e.g. `GroupCallController`'s `group_call_frame`
    /// broadcast, which also carries `GroupSenderKey`-sealed ciphertext) can
    /// tell a QUAD-wrapped envelope apart from that other format BEFORE
    /// attempting to parse or decrypt it — same dual-detection pattern
    /// `QAudionEngine.processIncomingAudio` already uses for
    /// `FrameEncoder.isValid` vs `WireRelayFrameCodec.decode`. A random
    /// AES-GCM ciphertext colliding with these 4 bytes is a 1-in-2^32 event,
    /// not a realistic false-positive source.
    public static func isQuadEnvelope(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let base = data.startIndex
        return data[base] == magic[0] && data[base + 1] == magic[1]
            && data[base + 2] == magic[2] && data[base + 3] == magic[3]
    }

    /// Creates a VOICE_ANALYSIS message (68-byte wire format).
    public static func createVoiceAnalysis(data: Data) -> Data {
        return wrapSimpleMessage(type: .voiceAnalysis, payload: data)
    }

    public static func createDcSdpOffer(sdp: String) -> Data {
        return wrapSimpleMessage(type: .dcSdpOffer, payload: Data(sdp.utf8))
    }

    public static func createDcSdpAnswer(sdp: String) -> Data {
        return wrapSimpleMessage(type: .dcSdpAnswer, payload: Data(sdp.utf8))
    }

    public static func createDcIce(candidate: String) -> Data {
        return wrapSimpleMessage(type: .dcIce, payload: Data(candidate.utf8))
    }

    // MARK: - Parse (supports both binary and JSON fallback)

    public static func parse(_ data: Data) -> Message? {
        guard data.count >= 7 else { return parseJson(data) }

        // Check for MAGIC header
        if data[0] == magic[0] && data[1] == magic[1] && data[2] == magic[2] && data[3] == magic[3] {
            return parseBinary(data)
        }

        // Fallback to JSON (backwards compat)
        return parseJson(data)
    }

    // MARK: - Binary protocol (Android-compatible)

    /// Wraps non-OFFER/ACCEPT messages in a simple format:
    /// [MAGIC][TYPE][VERSION][FEATURES=0][payloadLen 2B BE][0 kemLen 2B][payload]
    private static func wrapSimpleMessage(type: MessageType, payload: Data) -> Data {
        var data = Data()
        data.append(contentsOf: magic)
        data.append(type.rawValue)
        data.append(protocolVersion)
        data.append(UInt8(0))  // features = 0 for data messages
        appendUInt16BE(&data, UInt16(payload.count))  // pubKeyLen slot reused as payloadLen
        data.append(payload)
        appendUInt16BE(&data, UInt16(0))  // kemLen = 0
        return data
    }

    private static func parseBinary(_ data: Data) -> Message? {
        // Minimum header: MAGIC(4) + TYPE(1) + VERSION(1) + FEATURES(1) + pubKeyLen(2) + kemLen(2) = 11
        guard data.count >= 11 else { return nil }

        let typeRaw = data[4]
        let version = data[5]
        let features = data[6]
        guard version == protocolVersion else { return nil }
        guard let type = MessageType(rawValue: typeRaw) else { return nil }

        let pubKeyLen = Int(readUInt16BE(data, offset: 7))
        guard data.count >= 9 + pubKeyLen + 2 else { return nil }

        let pubKey = pubKeyLen > 0 ? data[9..<(9 + pubKeyLen)] : Data()
        let kemLenOffset = 9 + pubKeyLen
        let kemLen = Int(readUInt16BE(data, offset: kemLenOffset))
        let kemStart = kemLenOffset + 2
        guard data.count >= kemStart + kemLen else { return nil }

        let kemData = kemLen > 0 ? data[kemStart..<(kemStart + kemLen)] : Data()
        let pskOffset = kemStart + kemLen

        switch type {
        case .offer:
            // Parse PSK fingerprints: [2B count][2B len + UTF-8]...
            var fps: [String] = []
            if pskOffset + 2 <= data.count {
                let fpCount = Int(readUInt16BE(data, offset: pskOffset))
                var offset = pskOffset + 2
                for _ in 0..<fpCount {
                    guard offset + 2 <= data.count else { break }
                    let fpLen = Int(readUInt16BE(data, offset: offset))
                    offset += 2
                    guard offset + fpLen <= data.count else { break }
                    if let fp = String(data: data[offset..<(offset + fpLen)], encoding: .utf8) {
                        fps.append(fp)
                    }
                    offset += fpLen
                }
            }
            return .offer(publicKey: Data(pubKey), features: features, pskFingerprints: fps)

        case .accept:
            // For ACCEPT, ciphertext is in the KEM slot
            var selectedFp: String?
            if pskOffset + 2 <= data.count {
                let fpCount = Int(readUInt16BE(data, offset: pskOffset))
                if fpCount > 0 {
                    let fpLenOffset = pskOffset + 2
                    if fpLenOffset + 2 <= data.count {
                        let fpLen = Int(readUInt16BE(data, offset: fpLenOffset))
                        let fpStart = fpLenOffset + 2
                        if fpStart + fpLen <= data.count {
                            selectedFp = String(data: data[fpStart..<(fpStart + fpLen)], encoding: .utf8)
                        }
                    }
                }
            }
            return .accept(ciphertext: Data(kemData), pskFingerprint: selectedFp)

        case .audioData:
            guard let frames = parseAudioDataBatch(Data(pubKey)) else { return nil }
            return .audioData(frames: frames)

        case .voiceAnalysis:
            return .voiceAnalysis(data: Data(pubKey))

        case .dcSdpOffer:
            guard let sdp = String(data: pubKey, encoding: .utf8) else { return nil }
            return .dcSdpOffer(sdp: sdp)

        case .dcSdpAnswer:
            guard let sdp = String(data: pubKey, encoding: .utf8) else { return nil }
            return .dcSdpAnswer(sdp: sdp)

        case .dcIce:
            guard let c = String(data: pubKey, encoding: .utf8) else { return nil }
            return .dcIce(candidate: c)

        case .callHangup:
            let reason = String(data: pubKey, encoding: .utf8) ?? ""
            return .callHangup(reason: reason)

        case .keyExchangeOffer:
            // TODO(desktop-interop): wire into hybrid PQC handshake path
            return .keyExchangeOffer(payload: Data(pubKey))

        case .keyExchangeAccept:
            // TODO(desktop-interop): wire into hybrid PQC handshake path
            return .keyExchangeAccept(payload: Data(pubKey))
        }
    }

    // MARK: - New message builders for Desktop/Android interop

    public static func createCallHangup(reason: String = "") -> Data {
        return wrapSimpleMessage(type: .callHangup, payload: Data(reason.utf8))
    }

    public static func createKeyExchangeOffer(payload: Data) -> Data {
        return wrapSimpleMessage(type: .keyExchangeOffer, payload: payload)
    }

    public static func createKeyExchangeAccept(payload: Data) -> Data {
        return wrapSimpleMessage(type: .keyExchangeAccept, payload: payload)
    }

    // MARK: - JSON fallback (backwards compat)

    private static func parseJson(_ data: Data) -> Message? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        switch type {
        case "OFFER":
            guard let b64 = json["kemPublicKey"] as? String, let pk = Data(base64Encoded: b64) else { return nil }
            return .offer(publicKey: pk, features: defaultFeatures, pskFingerprints: json["pskFingerprints"] as? [String] ?? [])
        case "ACCEPT":
            guard let b64 = json["kemCiphertext"] as? String, let ct = Data(base64Encoded: b64) else { return nil }
            return .accept(ciphertext: ct, pskFingerprint: json["pskFingerprint"] as? String)
        default: return nil
        }
    }

    // MARK: - Helpers

    private static func appendUInt16BE(_ data: inout Data, _ value: UInt16) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 2))
    }

    private static func readUInt16BE(_ data: Data, offset: Int) -> UInt16 {
        data.withUnsafeBytes { UInt16(bigEndian: $0.load(fromByteOffset: offset, as: UInt16.self)) }
    }
}
