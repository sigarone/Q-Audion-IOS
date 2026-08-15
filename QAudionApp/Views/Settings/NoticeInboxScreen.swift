import SwiftUI

/// Server-pushed service notices — "Messaggi di servizio". 1:1 visual port
/// of Android `NoticeInboxScreen.kt`, driven by the same `NoticeService`
/// poll this file's neighbour ports from `NoticeRepository.kt`.
///
/// Newest first, dims once read, gets an error-tinted border when
/// `priority == "urgent"`. Tapping a card acks it — Android does the same
/// (`Card(... .clickable(onClick = onTap))`), there is no separate "mark
/// read" affordance.
struct NoticeInboxScreen: View {
    @ObservedObject private var service = NoticeService.shared

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            if service.notices.isEmpty {
                Text("Nessun messaggio")
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurfaceVariant)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Newest first — createdMs descending, matching the
                        // order Android's LazyColumn implicitly gets from
                        // the server response.
                        ForEach(sortedNewestFirst) { notice in
                            noticeCard(notice)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Messaggi di servizio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if service.unreadCount > 0 {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("Messaggi di servizio")
                            .qaudionStyle(type.titleMedium)
                            .foregroundStyle(scheme.onSurface)
                        Text("\(service.unreadCount)")
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(scheme.primary))
                            .accessibilityLabel("\(service.unreadCount) non letti")
                    }
                }
            }
        }
        .task {
            await service.pollOnce()
        }
    }

    private var sortedNewestFirst: [NoticeService.ServiceNotice] {
        service.notices.sorted { $0.createdMs > $1.createdMs }
    }

    private func noticeCard(_ notice: NoticeService.ServiceNotice) -> some View {
        let isUrgent = notice.priority == "urgent"
        let alpha: Double = notice.read ? 0.6 : 1.0
        return Button {
            Task { await service.ack(id: notice.id) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName(for: notice.kind))
                    .font(.system(size: 17))
                    .foregroundStyle(isUrgent ? extras.riskHigh : scheme.onSurfaceVariant.opacity(alpha))
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title)
                        .qaudionStyle(type.titleSmall)
                        .foregroundStyle(scheme.onSurfaceVariant.opacity(alpha))
                    Text(notice.body)
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurfaceVariant.opacity(alpha))
                    Text(relativeTime(notice.createdMs))
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.outline.opacity(alpha))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(scheme.surfaceVariant.opacity(alpha),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isUrgent ? extras.riskHigh : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func iconName(for kind: String) -> String {
        switch kind {
        case "outage":    return "exclamationmark.triangle"
        case "security":  return "lock.shield"
        case "expiry":    return "calendar"
        case "broadcast": return "megaphone"
        case "personal":  return "person"
        default:          return "megaphone"
        }
    }

    private func relativeTime(_ createdMs: Int64) -> String {
        let diff = Date().timeIntervalSince1970 - Double(createdMs) / 1000
        if diff < 60 { return "adesso" }
        if diff < 3600 { return "\(Int(diff / 60)) min fa" }
        if diff < 86400 { return "\(Int(diff / 3600))h fa" }
        if diff < 2 * 86400 { return "ieri" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: Date(timeIntervalSince1970: Double(createdMs) / 1000))
    }
}
