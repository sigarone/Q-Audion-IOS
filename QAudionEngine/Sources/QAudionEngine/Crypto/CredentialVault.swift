import Foundation

public final class CredentialVault {
    private let keyStore = QAudionKeyStore()

    public init() {}

    public func storeCredential(service: String, credential: Data) throws {
        try keyStore.storeKey(identifier: "cred_\(service)", keyData: credential)
    }

    public func loadCredential(service: String) -> Data? {
        keyStore.loadKey(identifier: "cred_\(service)")
    }

    public func deleteCredential(service: String) {
        keyStore.deleteKey(identifier: "cred_\(service)")
    }
}
