import SwiftUI
import QAudionEngine

/// Group-call counterpart of `InCallScreen`'s aggregating `securitySheet`
/// (see that file's header comment for the full 1:1 pattern — SAS +
/// handshake + cipher/key/epoch + transport + voice biometrics, all in
/// one dismissible sheet reached from a small always-visible shield
/// button). Presented from `GroupCallView.groupTrustBar`.
///
/// Same visual language as the 1:1 sheet (section chrome, chip shapes,
/// design tokens) and the SAME "n/a / omitted rather than fabricated"
/// discipline. What differs is structural, not stylistic — a group call
/// has N members instead of one peer:
///
///   - No SAS section: group calls have no in-call SAS ceremony of their
///     own (mirrors Android `PeerTrustRepository.toTrustLevel()`'s note,
///     referenced in `PeerTrustEvaluator`, that in-call SAS is a SEPARATE
///     mechanism from identity-pin trust — that mechanism simply doesn't
///     exist for groups). Per-member identity trust below reuses the
///     SAME persistent safety-number state machine `ContactDetailScreen`
///     already tracks per contact — no new verification concept invented.
///   - No transport/SFU-node section: this app build has no
///     client-visible SFU node identifier for group calls today (the
///     only node id that ever reaches the client is the transient
///     `nodeId` argument of `BCryptoGroupCallManager.onSfuTokenReceived`,
///     which is consumed internally by `GroupCallController` and never
///     surfaced to any `@Published` UI state) — so the section is
///     omitted entirely rather than showing a fabricated value.
///   - Overview section replaces the 1:1 "Handshake"/"Cifra e chiave"
///     pair with group-call constants: every group call bootstraps
///     member keys via ML-KEM-1024 (`KmsPreBootstrap`, W-GRPCALL gap-A2
///     port) and rides the AES-256-GCM LiveKit media path (video via
///     `LiveKitVideoFrameCryptor.derivedKeyBytes == 32`; the 2026-07-15/16
///     AES-256 LiveKit-parity fix), plus the live server-canonical
///     sender-key epoch (`BCryptoGroupCallManager.senderKeyEpoch`).
///
/// Does not modify `InCallScreen` in any way — a parallel, self-contained
/// view that reuses the same ambient design tokens and the same
/// `PeerTrustEvaluator` state machine, per spec.
struct GroupSecuritySheet: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @EnvironmentObject private var appState: AppState

    let participants: [GroupCallViewModel.ParticipantUI]
    let epoch: Int64
    let onDismiss: () -> Void

    /// Per-member trust evaluation, resolved async on appear — the SAME
    /// `PeerTrustEvaluator.evaluate` call `ContactDetailScreen.
    /// loadTrustEvaluation()` makes for its single contact, fanned out
    /// over the current roster. `nil` until resolved (or if resolution
    /// never completes, e.g. offline) — the row then shows the same
    /// "…" placeholder `ContactDetailScreen` uses while unresolved,
    /// never a guessed state.
    @State private var evaluations: [String: PeerTrustEvaluator.Evaluation] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().background(scheme.outline.opacity(0.35))
                VStack(alignment: .leading, spacing: 0) {
                    securitySection(title: "Panoramica") { overviewBody }
                    securitySection(title: "Membri · verifica identità", isLast: true) { membersBody }
                }
                .padding(.vertical, 4)
            }
        }
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
        .task { await loadAllEvaluations() }
    }

    // MARK: - Header (same chrome as InCallScreen.securitySheet's header)

    private var header: some View {
        HStack {
            Text("Sicurezza chiamata di gruppo")
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(scheme.surfaceVariant))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    /// Shared section chrome — identical shape to
    /// `InCallScreen.securitySection` (title row + content + bottom
    /// divider, omitted for the last section). Duplicated rather than
    /// reused from that file since it is a `private` method on
    /// `InCallScreen` — same "don't touch the 1:1 screen for a
    /// cosmetic-only reuse" call as `groupTrustChip` in `GroupCallView`.
    @ViewBuilder
    private func securitySection<Content: View>(
        title: String,
        isLast: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .qaudionStyle(type.labelSmall)
                .tracking(1.2)
                .foregroundStyle(scheme.onSurfaceVariant)
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        if !isLast {
            Divider().background(scheme.outline.opacity(0.25))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(1.0)
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Overview

    /// CIFRA MEDIA / HANDSHAKE are group-call constants (see the type doc
    /// comment for the source facts backing each string) — not per-call
    /// conditionals, because there is currently no capability-negotiation
    /// path for group-call media the way `CallCapabilities.Negotiated`
    /// exists for 1:1 (group calls have exactly one wire contract today).
    /// EPOCA / PARTECIPANTI are live values from the current call.
    private var overviewBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            infoRow("CIFRA MEDIA", "AES-256-GCM")
            infoRow("HANDSHAKE", "ML-KEM-1024 + X25519")
            infoRow("EPOCA", "\(epoch)")
            infoRow("PARTECIPANTI", "\(participants.count)")
        }
    }

    // MARK: - Members

    @ViewBuilder
    private var membersBody: some View {
        if participants.isEmpty {
            Text("Nessun partecipante.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(participants) { p in
                    memberRow(p)
                }
            }
        }
    }

    private func memberRow(_ p: GroupCallViewModel.ParticipantUI) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(p.displayName)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
                .lineLimit(1)
            Spacer(minLength: 8)
            memberTrustChip(evaluations[p.id])
        }
    }

    private func memberTrustChip(_ eval: PeerTrustEvaluator.Evaluation?) -> some View {
        let visual = memberTrustVisual(eval)
        return HStack(spacing: 4) {
            Image(systemName: visual.icon)
                .font(.system(size: 9, weight: .bold))
            Text(visual.label)
                .qaudionStyle(type.labelSmall)
                .tracking(0.4)
        }
        .foregroundStyle(visual.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(visual.color.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(visual.color.opacity(0.4), lineWidth: 1)
        )
    }

    /// Same 4-state machine `ContactDetailScreen`/`TrustVerificationCard`
    /// already use (`PeerTrustEvaluator.Evaluation.state` /
    /// `TrustSafetyNumberState`) — no new verification concept invented
    /// for groups. `nil` (evaluation not yet resolved for this member)
    /// renders the same "…" wording `ContactDetailScreen.
    /// lastVerificationLabel` shows while unresolved. `.unverified` — the
    /// evaluator's graceful-degrade state for "no real trust relationship
    /// could be established" (never met before, peer never published, no
    /// self identity, etc.) — is labelled honestly as no direct
    /// relationship rather than a bare "not verified", since for a group
    /// member that has never been a 1:1 contact this is the expected,
    /// non-alarming case (distinct from `.identityChanged`, which IS an
    /// alarm).
    private func memberTrustVisual(_ eval: PeerTrustEvaluator.Evaluation?) -> (icon: String, label: String, color: Color) {
        guard let eval else {
            return (icon: "ellipsis", label: "…", color: scheme.onSurfaceVariant)
        }
        switch eval.state {
        case .userVerified:
            return (icon: "checkmark.seal.fill", label: "Verificato", color: extras.success)
        case .identityPinnedTofu:
            return (icon: "lock.fill", label: "Non verificato", color: scheme.onSurfaceVariant)
        case .identityChanged:
            return (icon: "exclamationmark.octagon.fill", label: "Identità cambiata", color: extras.riskHigh)
        case .unverified:
            return (icon: "questionmark.circle", label: "Nessuna relazione diretta", color: scheme.onSurfaceVariant)
        }
    }

    /// Resolves trust for every current participant. Sequential (not a
    /// `TaskGroup`) — mirrors `ContactDetailScreen.loadTrustEvaluation()`'s
    /// single-await pattern exactly rather than introducing concurrent
    /// captures of `appState` (a non-`Sendable` `ObservableObject`) across
    /// task-group child closures, which would be new Swift-concurrency
    /// surface this file doesn't need: group calls cap at 8 participants
    /// (`GroupCallView` doc comment), so 8 sequential awaits is
    /// negligible and this whole `.task` runs once per sheet presentation.
    @MainActor
    private func loadAllEvaluations() async {
        for p in participants {
            let eval = await PeerTrustEvaluator.evaluate(peerUserId: p.id, provider: appState.liveProvider)
            evaluations[p.id] = eval
        }
    }
}
