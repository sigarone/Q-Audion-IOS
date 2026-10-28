import Foundation

/// The receipt of a withdrawal, kept in a file of the app container from the moment it arrives until the person has
/// saved it or closed its screen. The account is already gone from the server and the phone by then, so a kill of the
/// app between the answer and the save must not lose the only copy: the file is read again at the next launch.
///
/// The directory is the app's own (Application Support), never caches or temporary files: the wipe of an account clears
/// those.
public struct WithdrawalReceiptFile: Sendable {
    public static let fileName = "pending-withdrawal-receipt.json"

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `Application Support/legal`, or nil when the system gives no such folder.
    public static func appContainer() -> WithdrawalReceiptFile? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return WithdrawalReceiptFile(directory: base.appendingPathComponent("legal", isDirectory: true))
    }

    private var url: URL { directory.appendingPathComponent(Self.fileName) }

    public func save(_ receipt: WithdrawalReceipt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object = ["receipt_text": receipt.receiptText, "receipt_id": receipt.receiptId]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The receipt still waiting to be saved, or nil.
    public func load() -> WithdrawalReceipt? {
        guard let data = try? Data(contentsOf: url),
              let receipt = try? JSONDecoder().decode(WithdrawalReceipt.self, from: data),
              !receipt.receiptText.isEmpty else { return nil }
        return receipt
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// What closing the receipt screen does: straight away once the receipt was saved or shared, otherwise after a
/// question that offers Save.
public enum ReceiptClosePolicy {
    public enum Decision: Equatable, Sendable {
        case close
        case askToSave
    }

    public static func decide(saved: Bool) -> Decision { saved ? .close : .askToSave }
}
