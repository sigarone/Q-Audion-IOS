import Foundation

/// Why a user reports another person or a group (App Store 1.2).
///
/// One list for the three report screens (contact detail, chat menu, group info),
/// most serious first. `wireValue` is what travels in the report (the encrypted
/// body and the plaintext `report_category` form field), and it is the canonical
/// identifier of the category on the receiving side: `child_safety`,
/// `non_consensual_intimate_imagery`, `threat`, `abuse`, `spam`, `other`. Do not
/// rename a value here without changing it where reports are received.
///
/// A report carries the category, the ids of the reported person or group and
/// their name. It never carries message content: no log tail, no screenshot, no
/// text of the chat. The wording of every report dialog says so.
enum AbuseReportCategory: String, CaseIterable, Identifiable {
    case childSafety = "child_safety"
    case nonConsensualIntimateImagery = "non_consensual_intimate_imagery"
    case threat = "threat"
    case abuse = "abuse"
    case spam = "spam"
    case other = "other"

    var id: String { rawValue }

    /// The value sent to the server.
    var wireValue: String { rawValue }

    /// The label of the category button. Computed, not stored, so a change of the in-app language shows at once.
    var title: String {
        switch self {
        case .childSafety:
            return String(localized: "report.category.child_safety", defaultValue: "Minori (abuso o sfruttamento)", comment: "Report dialog: the reported person or group puts minors at risk (abuse or exploitation of children).")
        case .nonConsensualIntimateImagery:
            return String(localized: "report.category.intimate_images", defaultValue: "Immagini intime senza consenso", comment: "Report dialog: intimate images shared without the consent of the person shown.")
        case .threat:
            return String(localized: "report.category.threats", defaultValue: "Minacce", comment: "Report dialog: threats of violence or harm.")
        case .abuse:
            return String(localized: "Abuso o molestie")
        case .spam:
            return String(localized: "Spam")
        case .other:
            return String(localized: "Altro")
        }
    }
}
