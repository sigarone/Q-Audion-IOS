import Foundation

public enum QAudionCapabilityExchange {
    public enum Message {
        case offer(publicKey: Data, pskFingerprints: [String])
        case accept(ciphertext: Data, pskFingerprint: String?)
        case audioData(frame: Data)
        case voiceAnalysis(data: Data)
    }

    public static func createOffer(publicKey: Data, pskFingerprints: [String]) -> Data {
        let json: [String: Any] = ["type": "OFFER", "kemPublicKey": publicKey.base64EncodedString(), "pskFingerprints": pskFingerprints]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    public static func createAccept(ciphertext: Data, pskFingerprint: String?) -> Data {
        var json: [String: Any] = ["type": "ACCEPT", "kemCiphertext": ciphertext.base64EncodedString()]
        if let fp = pskFingerprint { json["pskFingerprint"] = fp }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    public static func parse(_ data: Data) -> Message? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        switch type {
        case "OFFER":
            guard let b64 = json["kemPublicKey"] as? String, let pk = Data(base64Encoded: b64) else { return nil }
            let fps = json["pskFingerprints"] as? [String] ?? []
            return .offer(publicKey: pk, pskFingerprints: fps)
        case "ACCEPT":
            guard let b64 = json["kemCiphertext"] as? String, let ct = Data(base64Encoded: b64) else { return nil }
            return .accept(ciphertext: ct, pskFingerprint: json["pskFingerprint"] as? String)
        case "AUDIO_DATA":
            guard let b64 = json["frame"] as? String, let frame = Data(base64Encoded: b64) else { return nil }
            return .audioData(frame: frame)
        default: return nil
        }
    }
}
