import Foundation

/// Capability exchange protocol matching Android binary format.
/// Wire format: [MAGIC 4B "QUAD"][VERSION 1B][TYPE 1B][LENGTH 2B BE][PAYLOAD NB]
public enum QAudionCapabilityExchange {

    // MARK: - Constants (match Android exactly)
    private static let magic: [UInt8] = [0x51, 0x41, 0x55, 0x44]  // "QUAD"
    private static let protocolVersion: UInt8 = 0x01

    public enum MessageType: UInt8 {
        case offer = 0x01
        case accept = 0x02
        case audioData = 0x03
        case voiceAnalysis = 0x04
        case dcSdpOffer = 0x05
        case dcSdpAnswer = 0x06
        case dcIce = 0x07
    }

    public enum Message {
        case offer(publicKey: Data, pskFingerprints: [String])
        case accept(ciphertext: Data, pskFingerprint: String?)
        case audioData(frame: Data)
        case voiceAnalysis(data: Data)
        case dcSdpOffer(sdp: String)
        case dcSdpAnswer(sdp: String)
        case dcIce(candidate: String)
    }

    // MARK: - Serialize (binary, matching Android)

    public static func createOffer(publicKey: Data, pskFingerprints: [String]) -> Data {
        // Payload: [pubKeyLen 2B BE][pubKey NB][fpCount 1B][fpLen 1B + fpData]...
        var payload = Data()
        appendUInt16BE(&payload, UInt16(publicKey.count))
        payload.append(publicKey)
        payload.append(UInt8(pskFingerprints.count))
        for fp in pskFingerprints {
            let fpData = Data(fp.utf8)
            payload.append(UInt8(fpData.count))
            payload.append(fpData)
        }
        return wrapMessage(type: .offer, payload: payload)
    }

    public static func createAccept(ciphertext: Data, pskFingerprint: String?) -> Data {
        var payload = Data()
        appendUInt16BE(&payload, UInt16(ciphertext.count))
        payload.append(ciphertext)
        if let fp = pskFingerprint {
            let fpData = Data(fp.utf8)
            payload.append(UInt8(1))  // has fingerprint
            payload.append(UInt8(fpData.count))
            payload.append(fpData)
        } else {
            payload.append(UInt8(0))  // no fingerprint
        }
        return wrapMessage(type: .accept, payload: payload)
    }

    public static func createAudioData(frames: [Data]) -> Data {
        var payload = Data()
        appendUInt16BE(&payload, UInt16(frames.count))
        for frame in frames {
            appendUInt16BE(&payload, UInt16(frame.count))
            payload.append(frame)
        }
        return wrapMessage(type: .audioData, payload: payload)
    }

    public static func createVoiceAnalysis(data: Data) -> Data {
        return wrapMessage(type: .voiceAnalysis, payload: data)
    }

    public static func createDcSdpOffer(sdp: String) -> Data {
        return wrapMessage(type: .dcSdpOffer, payload: Data(sdp.utf8))
    }

    public static func createDcSdpAnswer(sdp: String) -> Data {
        return wrapMessage(type: .dcSdpAnswer, payload: Data(sdp.utf8))
    }

    public static func createDcIce(candidate: String) -> Data {
        return wrapMessage(type: .dcIce, payload: Data(candidate.utf8))
    }

    // MARK: - Parse (supports both binary and JSON fallback)

    public static func parse(_ data: Data) -> Message? {
        guard data.count >= 8 else { return parseJson(data) }

        // Check for MAGIC header
        if data[0] == magic[0] && data[1] == magic[1] && data[2] == magic[2] && data[3] == magic[3] {
            return parseBinary(data)
        }

        // Fallback to JSON (backwards compat)
        return parseJson(data)
    }

    // MARK: - Binary protocol

    private static func wrapMessage(type: MessageType, payload: Data) -> Data {
        var data = Data()
        data.append(contentsOf: magic)           // 4 bytes: "QUAD"
        data.append(protocolVersion)              // 1 byte: version
        data.append(type.rawValue)                // 1 byte: message type
        appendUInt16BE(&data, UInt16(payload.count))  // 2 bytes: payload length
        data.append(payload)                      // N bytes: payload
        return data
    }

    private static func parseBinary(_ data: Data) -> Message? {
        guard data.count >= 8 else { return nil }
        let version = data[4]
        guard version == protocolVersion else { return nil }
        let typeRaw = data[5]
        guard let type = MessageType(rawValue: typeRaw) else { return nil }
        let payloadLen = Int(readUInt16BE(data, offset: 6))
        guard data.count >= 8 + payloadLen else { return nil }
        let payload = data[8..<(8 + payloadLen)]

        switch type {
        case .offer:
            guard payload.count >= 3 else { return nil }
            let pkLen = Int(readUInt16BE(Data(payload), offset: 0))
            guard payload.count >= 2 + pkLen + 1 else { return nil }
            let pk = payload[(payload.startIndex + 2)..<(payload.startIndex + 2 + pkLen)]
            let fpCount = Int(payload[payload.startIndex + 2 + pkLen])
            var fps: [String] = []
            var offset = payload.startIndex + 2 + pkLen + 1
            for _ in 0..<fpCount {
                guard offset < payload.endIndex else { break }
                let fpLen = Int(payload[offset]); offset += 1
                guard offset + fpLen <= payload.endIndex else { break }
                if let fp = String(data: payload[offset..<(offset + fpLen)], encoding: .utf8) { fps.append(fp) }
                offset += fpLen
            }
            return .offer(publicKey: Data(pk), pskFingerprints: fps)

        case .accept:
            guard payload.count >= 3 else { return nil }
            let ctLen = Int(readUInt16BE(Data(payload), offset: 0))
            guard payload.count >= 2 + ctLen + 1 else { return nil }
            let ct = payload[(payload.startIndex + 2)..<(payload.startIndex + 2 + ctLen)]
            let hasFp = payload[payload.startIndex + 2 + ctLen] != 0
            var fp: String? = nil
            if hasFp {
                let fpLenOffset = payload.startIndex + 2 + ctLen + 1
                guard fpLenOffset < payload.endIndex else { return .accept(ciphertext: Data(ct), pskFingerprint: nil) }
                let fpLen = Int(payload[fpLenOffset])
                let fpStart = fpLenOffset + 1
                if fpStart + fpLen <= payload.endIndex {
                    fp = String(data: payload[fpStart..<(fpStart + fpLen)], encoding: .utf8)
                }
            }
            return .accept(ciphertext: Data(ct), pskFingerprint: fp)

        case .audioData:
            guard payload.count >= 2 else { return nil }
            // Just return the raw payload for audio frames
            return .audioData(frame: Data(payload))

        case .voiceAnalysis:
            return .voiceAnalysis(data: Data(payload))

        case .dcSdpOffer:
            guard let sdp = String(data: payload, encoding: .utf8) else { return nil }
            return .dcSdpOffer(sdp: sdp)

        case .dcSdpAnswer:
            guard let sdp = String(data: payload, encoding: .utf8) else { return nil }
            return .dcSdpAnswer(sdp: sdp)

        case .dcIce:
            guard let candidate = String(data: payload, encoding: .utf8) else { return nil }
            return .dcIce(candidate: candidate)
        }
    }

    // MARK: - JSON fallback (backwards compat)

    private static func parseJson(_ data: Data) -> Message? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        switch type {
        case "OFFER":
            guard let b64 = json["kemPublicKey"] as? String, let pk = Data(base64Encoded: b64) else { return nil }
            return .offer(publicKey: pk, pskFingerprints: json["pskFingerprints"] as? [String] ?? [])
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
