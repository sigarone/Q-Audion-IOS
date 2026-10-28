import Foundation

/// The specific-approval text (art. 21.1-bis features and the clauses of arts. 1341-1342 c.c.), shown behind
/// a "Mostra" link next to its box.
public struct LegalSpecificApproval: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let text: String

    public init(id: String, title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}

/// The legal document as the server serves it (`GET /api/v1/legal/terms`). The server is the only source
/// of these texts: the app never carries a copy.
public struct LegalTermsDocument: Codable, Equatable, Sendable {
    public let version: String
    public let lang: String
    public let title: String
    public let bodyMarkdown: String
    public let specificApproval: LegalSpecificApproval
    public let emergencyNotice: String
    public let withdrawalInfo: String

    public init(version: String, lang: String, title: String, bodyMarkdown: String,
                specificApproval: LegalSpecificApproval, emergencyNotice: String, withdrawalInfo: String) {
        self.version = version
        self.lang = lang
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.specificApproval = specificApproval
        self.emergencyNotice = emergencyNotice
        self.withdrawalInfo = withdrawalInfo
    }

    enum CodingKeys: String, CodingKey {
        case version, lang, title
        case specificApproval = "specific_approval"
        case bodyMarkdown = "body_markdown"
        case emergencyNotice = "emergency_notice"
        case withdrawalInfo = "withdrawal_info"
    }
}

/// A document together with the SHA-256 of the exact bytes it was read from. The server serves its embedded
/// bytes unchanged and publishes the digest of those same bytes, so the digest computed here is the one the
/// acceptance has to carry.
public struct LegalTermsFetch: Equatable, Sendable {
    public let document: LegalTermsDocument
    public let sha256: String

    public init(document: LegalTermsDocument, sha256: String) {
        self.document = document
        self.sha256 = sha256
    }
}

/// `GET /api/v1/legal/status`.
public struct LegalStatus: Decodable, Equatable, Sendable {
    public let currentVersion: String
    public let acceptedVersion: String
    public let acceptanceRequired: Bool

    public init(currentVersion: String, acceptedVersion: String, acceptanceRequired: Bool) {
        self.currentVersion = currentVersion
        self.acceptedVersion = acceptedVersion
        self.acceptanceRequired = acceptanceRequired
    }

    enum CodingKeys: String, CodingKey {
        case currentVersion = "current_version"
        case acceptedVersion = "accepted_version"
        case acceptanceRequired = "acceptance_required"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentVersion = try c.decodeIfPresent(String.self, forKey: .currentVersion) ?? ""
        acceptedVersion = try c.decodeIfPresent(String.self, forKey: .acceptedVersion) ?? ""
        acceptanceRequired = try c.decode(Bool.self, forKey: .acceptanceRequired)
    }
}

/// `POST /api/v1/legal/withdraw` answer: the receipt of the withdrawal.
public struct WithdrawalReceipt: Decodable, Equatable, Sendable {
    public let receiptText: String
    public let receiptId: String

    public init(receiptText: String, receiptId: String) {
        self.receiptText = receiptText
        self.receiptId = receiptId
    }

    enum CodingKeys: String, CodingKey {
        case receiptText = "receipt_text"
        case receiptId = "receipt_id"
    }
}

/// Which of the two published languages a device gets: `it` for an Italian app language, `en` for every other.
public enum LegalLanguage {
    public static func code(forAppLanguage languageCode: String) -> String {
        let base = languageCode.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? ""
        return base == "it" ? "it" : "en"
    }
}
