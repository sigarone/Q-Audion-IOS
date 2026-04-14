import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

/// Manages sovereign cryptographic identity for Q-Audion iOS.
/// Mirrors Android SovereignIdentityManager for cross-platform interop.
///
/// Identity = X25519 encryption key + Ed25519 signing key + server URL.
/// No phone number, email, or personal data required.
///
/// Binary wire format matches Android exactly for QR/link exchange.
public final class SovereignIdentityManager {

    // MARK: - Types

    public enum IdentityType: UInt8, Codable {
        case sovereign = 0
        case phone = 1
        case email = 2
    }

    public struct SovereignIdentity {
        public let userId: String
        public let encryptionPrivate: Data  // X25519, 32 bytes
        public let encryptionPublic: Data   // X25519, 32 bytes
        public let signingPrivate: Data     // Ed25519, 32 bytes (seed)
        public let signingPublic: Data      // Ed25519, 32 bytes
        public let serverUrl: String
        public let displayName: String?
        public let identityType: IdentityType

        /// Zeroize private key material from memory.
        public func zeroize() {
            encryptionPrivate.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    memset(UnsafeMutableRawPointer(mutating: base), 0, ptr.count)
                }
            }
            signingPrivate.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    memset(UnsafeMutableRawPointer(mutating: base), 0, ptr.count)
                }
            }
        }
    }

    // MARK: - Constants (match Android)

    private static let linkScheme = "qaudion://id/"
    private static let identityVersion: UInt8 = 0x01
    private static let keychainService = "com.bcrypto.qaudion.sovereign"

    // MARK: - Generate Identity

    /// Generate a new sovereign identity with fresh X25519 and Ed25519 keypairs.
    public func generateIdentity(serverUrl: String, displayName: String?) -> SovereignIdentity {
        let encKey = Curve25519.KeyAgreement.PrivateKey()
        let sigKey = Curve25519.Signing.PrivateKey()

        return SovereignIdentity(
            userId: UUID().uuidString,
            encryptionPrivate: encKey.rawRepresentation,
            encryptionPublic: encKey.publicKey.rawRepresentation,
            signingPrivate: sigKey.rawRepresentation,
            signingPublic: sigKey.publicKey.rawRepresentation,
            serverUrl: serverUrl,
            displayName: displayName,
            identityType: .sovereign
        )
    }

    // MARK: - Export / Import (wire format matches Android)

    /// Export identity as shareable link: qaudion://id/<base64url(version || encPub || sigPub || serverUrl || displayName)>
    public func exportAsLink(_ identity: SovereignIdentity) -> String {
        let data = encodePublicIdentity(identity)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.linkScheme + encoded
    }

    /// Export as raw bytes for QR code.
    public func exportAsQrData(_ identity: SovereignIdentity) -> Data {
        return encodePublicIdentity(identity)
    }

    /// Parse identity link or QR data. Returns public-only identity.
    public func parseIdentityLink(_ link: String) -> SovereignIdentity? {
        let b64: String
        if link.hasPrefix(Self.linkScheme) {
            b64 = String(link.dropFirst(Self.linkScheme.count))
        } else {
            b64 = link
        }
        // URL-safe base64 -> standard base64
        let standard = b64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        return decodePublicIdentity(data)
    }

    // MARK: - Challenge-Response Auth (Ed25519)

    /// Sign a 32-byte challenge from the server.
    public func signChallenge(_ challenge: Data, identity: SovereignIdentity) throws -> Data {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.signingPrivate)
        return try privateKey.signature(for: challenge)
    }

    /// Verify a signed challenge from a contact.
    public func verifySignature(publicKey: Data, challenge: Data, signature: Data) -> Bool {
        guard let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return pubKey.isValidSignature(signature, for: challenge)
    }

    // MARK: - X25519 Key Agreement

    /// Derive 32-byte shared secret via X25519 DH.
    public func deriveSharedSecret(identity: SovereignIdentity, remotePublicKey: Data) throws -> Data {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identity.encryptionPrivate)
        let remotePub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: remotePub)
        return shared.withUnsafeBytes { Data($0) }
    }

    // MARK: - Sovereign Server Registration

    /// Register sovereign identity with server.
    /// POST /api/v1/register/sovereign
    public func registerWithServer(identity: SovereignIdentity, rest: BCryptoRestClient) async throws -> (userId: String, challenge: String) {
        let dict: [String: Any] = [
            "signing_pub_key": identity.signingPublic.map { String(format: "%02x", $0) }.joined(),
            "encryption_pub_key": identity.encryptionPublic.map { String(format: "%02x", $0) }.joined(),
            "display_name": identity.displayName ?? "",
            "server_url": identity.serverUrl
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/register/sovereign", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = json["user_id"] as? String,
              let challenge = json["challenge"] as? String else {
            throw BCryptoError.decodingError
        }
        return (userId, challenge)
    }

    /// Verify sovereign registration by signing the challenge.
    /// POST /api/v1/register/sovereign/verify
    public func verifySovereignRegistration(userId: String, signature: Data, rest: BCryptoRestClient) async throws -> AuthCredentials {
        let dict: [String: Any] = [
            "user_id": userId,
            "signature": signature.map { String(format: "%02x", $0) }.joined()
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/register/sovereign/verify", body: body)
        return try JSONDecoder().decode(AuthCredentials.self, from: data)
    }

    /// Request auth challenge for existing sovereign user.
    /// POST /api/v1/auth/challenge
    public func requestAuthChallenge(userId: String, rest: BCryptoRestClient) async throws -> String {
        let dict = ["user_id": userId]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/auth/challenge", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let challenge = json["challenge"] as? String else {
            throw BCryptoError.decodingError
        }
        return challenge
    }

    /// Verify auth challenge.
    /// POST /api/v1/auth/challenge/verify
    public func verifyAuthChallenge(userId: String, signature: Data, rest: BCryptoRestClient) async throws -> AuthCredentials {
        let dict: [String: Any] = [
            "user_id": userId,
            "signature": signature.map { String(format: "%02x", $0) }.joined()
        ]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/auth/challenge/verify", body: body)
        return try JSONDecoder().decode(AuthCredentials.self, from: data)
    }

    // MARK: - Keychain Storage

    /// Save identity encrypted in iOS Keychain.
    public func saveIdentity(_ identity: SovereignIdentity) throws {
        let data = serializeIdentity(identity)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "primary",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            let search: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.keychainService,
                kSecAttrAccount as String: "primary"
            ]
            let updateStatus = SecItemUpdate(search as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeyVaultError.storeFailed(updateStatus) }
        } else if status != errSecSuccess {
            throw KeyVaultError.storeFailed(status)
        }
    }

    /// Load stored sovereign identity.
    public func loadIdentity() -> SovereignIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "primary",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return deserializeIdentity(data)
    }

    /// Check if sovereign identity exists.
    public func hasSovereignIdentity() -> Bool { loadIdentity() != nil }

    // MARK: - Binary Serialization (matches Android wire format)

    /// Full identity: [version:1][encPriv:32][encPub:32][sigPriv:32][sigPub:32]
    ///   [userIdLen:2BE][userId:N][serverUrlLen:2BE][serverUrl:M][nameLen:2BE][name:T][identityType:1]
    private func serializeIdentity(_ id: SovereignIdentity) -> Data {
        var data = Data()
        data.append(Self.identityVersion)
        data.append(id.encryptionPrivate)
        data.append(id.encryptionPublic)
        data.append(id.signingPrivate)
        data.append(id.signingPublic)
        let userIdBytes = Data(id.userId.utf8)
        appendUInt16BE(&data, UInt16(userIdBytes.count))
        data.append(userIdBytes)
        let serverBytes = Data(id.serverUrl.utf8)
        appendUInt16BE(&data, UInt16(serverBytes.count))
        data.append(serverBytes)
        let nameBytes = Data((id.displayName ?? "").utf8)
        appendUInt16BE(&data, UInt16(nameBytes.count))
        data.append(nameBytes)
        data.append(id.identityType.rawValue)
        return data
    }

    private func deserializeIdentity(_ data: Data) -> SovereignIdentity? {
        guard data.count >= 1 + 32 + 32 + 32 + 32 + 2 else { return nil }
        var offset = 0
        let version = data[offset]; offset += 1
        guard version == Self.identityVersion else { return nil }

        let encPriv = data[offset..<(offset + 32)]; offset += 32
        let encPub = data[offset..<(offset + 32)]; offset += 32
        let sigPriv = data[offset..<(offset + 32)]; offset += 32
        let sigPub = data[offset..<(offset + 32)]; offset += 32

        guard data.count >= offset + 2 else { return nil }
        let userIdLen = Int(readUInt16BE(data, offset: offset)); offset += 2
        guard data.count >= offset + userIdLen + 2 else { return nil }
        let userId = String(data: data[offset..<(offset + userIdLen)], encoding: .utf8) ?? ""; offset += userIdLen

        let serverLen = Int(readUInt16BE(data, offset: offset)); offset += 2
        guard data.count >= offset + serverLen + 2 else { return nil }
        let serverUrl = String(data: data[offset..<(offset + serverLen)], encoding: .utf8) ?? ""; offset += serverLen

        let nameLen = Int(readUInt16BE(data, offset: offset)); offset += 2
        let displayName: String? = nameLen > 0 && data.count >= offset + nameLen
            ? String(data: data[offset..<(offset + nameLen)], encoding: .utf8) : nil
        offset += nameLen

        let identityType: IdentityType = data.count > offset
            ? (IdentityType(rawValue: data[offset]) ?? .sovereign) : .sovereign

        return SovereignIdentity(
            userId: userId, encryptionPrivate: Data(encPriv), encryptionPublic: Data(encPub),
            signingPrivate: Data(sigPriv), signingPublic: Data(sigPub),
            serverUrl: serverUrl, displayName: displayName, identityType: identityType
        )
    }

    /// Public identity (for links/QR): [version:1][encPub:32][sigPub:32][serverUrlLen:2BE][serverUrl:N][nameLen:2BE][name:M]
    private func encodePublicIdentity(_ id: SovereignIdentity) -> Data {
        var data = Data()
        data.append(Self.identityVersion)
        data.append(id.encryptionPublic)
        data.append(id.signingPublic)
        let serverBytes = Data(id.serverUrl.utf8)
        appendUInt16BE(&data, UInt16(serverBytes.count))
        data.append(serverBytes)
        let nameBytes = Data((id.displayName ?? "").utf8)
        appendUInt16BE(&data, UInt16(nameBytes.count))
        data.append(nameBytes)
        return data
    }

    private func decodePublicIdentity(_ data: Data) -> SovereignIdentity? {
        guard data.count >= 1 + 32 + 32 + 2 else { return nil }
        var offset = 0
        let version = data[offset]; offset += 1
        guard version == Self.identityVersion else { return nil }

        let encPub = data[offset..<(offset + 32)]; offset += 32
        let sigPub = data[offset..<(offset + 32)]; offset += 32

        guard data.count >= offset + 2 else { return nil }
        let serverLen = Int(readUInt16BE(data, offset: offset)); offset += 2
        guard data.count >= offset + serverLen + 2 else { return nil }
        let serverUrl = String(data: data[offset..<(offset + serverLen)], encoding: .utf8) ?? ""; offset += serverLen

        let nameLen = Int(readUInt16BE(data, offset: offset)); offset += 2
        let displayName: String? = nameLen > 0 && data.count >= offset + nameLen
            ? String(data: data[offset..<(offset + nameLen)], encoding: .utf8) : nil

        return SovereignIdentity(
            userId: "", encryptionPrivate: Data(count: 32), encryptionPublic: Data(encPub),
            signingPrivate: Data(count: 32), signingPublic: Data(sigPub),
            serverUrl: serverUrl, displayName: displayName, identityType: .sovereign
        )
    }

    // MARK: - Helpers

    private func appendUInt16BE(_ data: inout Data, _ value: UInt16) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 2))
    }

    private func readUInt16BE(_ data: Data, offset: Int) -> UInt16 {
        data.withUnsafeBytes { UInt16(bigEndian: $0.load(fromByteOffset: offset, as: UInt16.self)) }
    }
}
