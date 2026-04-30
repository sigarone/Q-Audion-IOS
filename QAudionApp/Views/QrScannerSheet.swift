import SwiftUI
import QAudionEngine

/// High-level scan-and-act sheet.
///
/// Composes `QrScannerView` (camera preview) with `QrPayloadRouter` (codec
/// dispatch) and a result-detail screen tailored to each payload kind.
/// Handles the full UX cycle:
///
/// 1. Camera preview + reticle.
/// 2. On detection, route the raw string and show a payload-specific summary.
/// 3. User taps **Confirm** → caller-provided `onAccepted` closure fires; the
///    sheet dismisses itself.
/// 4. **Scan another** returns to the live camera (resets the per-frame guard).
/// 5. **Cancel** dismisses without firing any callback.
///
/// Caller integration:
/// ```swift
/// .sheet(isPresented: $showingScanner) {
///     QrScannerSheet(onAccepted: handleScannedPayload)
/// }
/// ```
struct QrScannerSheet: View {
    /// Caller-supplied handler for an accepted (decoded + confirmed) payload.
    /// Invoked just before the sheet dismisses.
    let onAccepted: (QrPayloadRouter.Decoded) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .scanning

    private enum Phase: Equatable {
        case scanning
        case decoded(QrPayloadRouter.Decoded)
    }

    var body: some View {
        Group {
            switch phase {
            case .scanning:
                QrScannerView(
                    onScanned: { raw in
                        phase = .decoded(QrPayloadRouter.route(raw))
                    },
                    onCancel: { dismiss() }
                )
            case .decoded(let decoded):
                NavigationStack {
                    DecodedDetailView(decoded: decoded,
                                      onAccept: { onAccepted(decoded); dismiss() },
                                      onScanAgain: { phase = .scanning },
                                      onCancel: { dismiss() })
                }
            }
        }
    }
}

// MARK: - Result detail

/// Renders a payload-specific summary plus accept / rescan / cancel actions.
private struct DecodedDetailView: View {
    let decoded: QrPayloadRouter.Decoded
    let onAccept: () -> Void
    let onScanAgain: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            Section { headerSection }
            detailSection
            actionSection
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Annulla") { onCancel() }
            }
        }
    }

    private var title: String {
        switch decoded {
        case .identity:    return "Identità contatto"
        case .deviceLink:  return "Accoppiamento dispositivo"
        case .fastSetup:   return "Configurazione rapida"
        case .groupInvite: return "Invito al gruppo"
        case .invalid:     return "Codice non valido"
        case .unknown:     return "Codice sconosciuto"
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 16) {
            iconView
            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var iconView: some View {
        let (system, color): (String, Color) = {
            switch decoded {
            case .identity: return ("person.text.rectangle.fill", .blue)
            case .deviceLink: return ("ipad.and.iphone", .purple)
            case .fastSetup: return ("bolt.shield.fill", .orange)
            case .groupInvite: return ("person.3.fill", .green)
            case .invalid: return ("exclamationmark.triangle.fill", .red)
            case .unknown: return ("questionmark.diamond.fill", .gray)
            }
        }()
        return Image(systemName: system)
            .font(.system(size: 32))
            .foregroundStyle(color)
            .frame(width: 48, height: 48)
    }

    private var headerTitle: String {
        switch decoded {
        case .identity(let id): return id.userId
        case .deviceLink(let dl): return dl.userId
        case .fastSetup(let fs): return fs.userId
        case .groupInvite(let gi):
            return gi.groupName.isEmpty ? "Gruppo" : gi.groupName
        case .invalid(let kind, _): return "Codice \(kind.rawValue) non valido"
        case .unknown: return "QR non riconosciuto"
        }
    }

    private var headerSubtitle: String {
        switch decoded {
        case .identity: return "QR identità (stampabile)"
        case .deviceLink: return "Codice di accoppiamento dispositivo"
        case .fastSetup: return "Codice di onboarding emesso dal server"
        case .groupInvite: return "Invito client-generated a un gruppo"
        case .invalid(_, let reason): return reason
        case .unknown(let prefix): return "Prefisso: \"\(prefix)…\""
        }
    }

    @ViewBuilder
    private var detailSection: some View {
        switch decoded {
        case .identity(let identity):
            Section("Identità") {
                LabeledContent("User ID") {
                    Text(identity.userId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Chiave pubblica") {
                    Text(identity.pubkey.map { String(format: "%02x", $0) }.joined()
                            .prefix(32) + "…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Fingerprint") {
                    Text((try? Fingerprint.format(pubkey: identity.pubkey)) ?? "????.????.????.????")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        case .deviceLink(let dl):
            Section("Dispositivo") {
                LabeledContent("User ID") {
                    Text(dl.userId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Chiave pubblica") {
                    Text(dl.pubkey.map { String(format: "%02x", $0) }.joined()
                            .prefix(32) + "…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Auth code") {
                    Text(dl.authCode.map { String(format: "%02x", $0) }.joined())
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        case .fastSetup(let fs):
            Section("Configurazione") {
                LabeledContent("User ID") {
                    Text(fs.userId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let ext = fs.dialExtension {
                    LabeledContent("Interno") {
                        Text(ext)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Server") {
                    Text(fs.serverUrl.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                let expiresIn = expiresInDescription(fs.expiresAtUnixMs)
                LabeledContent("Scadenza") {
                    Text(expiresIn)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .groupInvite(let gi):
            Section("Gruppo") {
                LabeledContent("ID gruppo") {
                    Text(gi.groupId.uuidString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !gi.groupName.isEmpty {
                    LabeledContent("Nome") {
                        Text(gi.groupName)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Versione payload") {
                    Text("v\(gi.version)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Tocca \"Conferma\" per richiedere l'ingresso al gruppo. L'admin del gruppo dovrà approvare la richiesta server-side.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .invalid(_, let reason):
            Section("Motivo") {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        case .unknown:
            Section {
                Text("Questo QR non corrisponde a nessun formato Q-Audion. Assicurati di scansionare un codice generato da Q-Audion (identità, device-link, configurazione rapida o invito gruppo).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            switch decoded {
            case .identity, .deviceLink, .fastSetup, .groupInvite:
                Button {
                    onAccept()
                } label: {
                    Label(acceptLabel, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .invalid, .unknown:
                EmptyView()
            }
            Button {
                onScanAgain()
            } label: {
                Label("Scansiona un altro", systemImage: "qrcode.viewfinder")
            }
        }
    }

    private var acceptLabel: String {
        switch decoded {
        case .identity:    return "Aggiungi come contatto"
        case .deviceLink:  return "Accoppia questo dispositivo"
        case .fastSetup:   return "Usa questo codice di setup"
        case .groupInvite: return "Richiedi ingresso al gruppo"
        default:           return "Conferma"
        }
    }

    /// Best-effort relative description of expiry time. Past expiries should
    /// already be rejected by `FastSetupQrCode.decode` (it throws `.expired`),
    /// so this only formats a forward-looking duration.
    private func expiresInDescription(_ expiresAtUnixMs: Int64) -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let deltaSec = (expiresAtUnixMs - nowMs) / 1000
        if deltaSec < 0 { return "scaduto" }
        if deltaSec < 60 { return "tra \(deltaSec)s" }
        if deltaSec < 3600 { return "tra \(deltaSec / 60)m" }
        if deltaSec < 86400 { return "tra \(deltaSec / 3600)h" }
        return "tra \(deltaSec / 86400)g"
    }
}
