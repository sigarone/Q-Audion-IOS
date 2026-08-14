import SwiftUI

/// Day separator used inside the chat detail's message list. Renders a
/// centred capsule with the human-readable day label ("Oggi", "Ieri",
/// "lun 15 gen", "Q-Audion · 12 mar 2024") between two faint hairlines.
///
/// 1:1 visual port of Android
/// `qaudion-android-new/feature/feature-chat/.../components/DayHeader.kt`.
///
/// Format rules (Italian, matching Android `DateUtils`):
///   - same calendar day as `now()` → "Oggi"
///   - calendar yesterday        → "Ieri"
///   - within last 7 days         → "EEE d MMM"   ("mar 16 apr")
///   - older                      → "d MMM yyyy"  ("4 set 2025")
struct DayHeader: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(scheme.outline.opacity(0.35))
                .frame(height: 0.5)
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(1.0)
                .foregroundStyle(scheme.onSurfaceVariant)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(scheme.surface.opacity(0.65)))
                .layoutPriority(1)
            Rectangle()
                .fill(scheme.outline.opacity(0.35))
                .frame(height: 0.5)
        }
        .padding(.vertical, 4)
    }

    private static let thisWeekFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEE d MMM"
        return f
    }()

    private static let oldDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private var label: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Oggi" }
        if cal.isDateInYesterday(date) { return "Ieri" }

        let now = Date()
        if let days = cal.dateComponents([.day], from: date, to: now).day,
           days < 7 {
            return Self.thisWeekFormatter.string(from: date)
        } else {
            return Self.oldDateFormatter.string(from: date)
        }
    }
}

#Preview {
    VStack(spacing: 4) {
        DayHeader(date: Date())
        DayHeader(date: Date().addingTimeInterval(-86_400))
        DayHeader(date: Date().addingTimeInterval(-86_400 * 3))
        DayHeader(date: Date().addingTimeInterval(-86_400 * 90))
    }
    .padding()
    .frame(maxWidth: .infinity)
    .qAudionTheme(dark: true)
}
