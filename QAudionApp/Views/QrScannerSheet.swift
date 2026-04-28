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
                Button("Cancel") { onCancel() }
            }
        }
    }

    private var title: String {
        switch decoded {
        case .identity: return "Contact Identity"
        case .deviceLink: return "Device Pairing"
        case .fastSetup: return "Fast Setup"
        case .invalid: return "Invalid Code"
        case .unknown: return "Unknown Code"
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
        case .invalid(let kind, _): return "Invalid \(kind.rawValue) code"
        case .unknown: return "Unrecognised QR code"
        }
    }

    private var headerSubtitle: String {
        switch decoded {
        case .identity: return "Identity QR (printable)"
        case .deviceLink: return "Device-linking pairing code"
        case .fastSetup: return "Server-issued onboarding code"
        case .invalid(_, let reason): return reason
        case .unknown(let prefix): return "Prefix: \"\(prefix)…\""
        }
    }

    @ViewBuilder
    private var detailSection: some View {
        switch decoded {
        case .identity(let identity):
            Section("Identity") {
                LabeledContent("User ID") {
                    Text(identity.userId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Public key") {
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
            Section("Device") {
                LabeledContent("User ID") {
                    Text(dl.userId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Public key") {
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
            Section("Setup") {
                LabeledContent("User ID") {
                    Text(fs.userId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let ext = fs.dialExtension {
                    LabeledContent("Extension") {
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
                LabeledContent("Expires") {
                    Text(expiresIn)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .invalid(_, let reason):
            Section("Reason") {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        case .unknown:
            Section {
                Text("This QR code does not match any Q-Audion format. Make sure you're scanning a code generated by Q-Audion (identity, device-link, or fast setup).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            switch decoded {
            case .identity, .deviceLink, .fastSetup:
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
                Label("Scan another", systemImage: "qrcode.viewfinder")
            }
        }
    }

    private var acceptLabel: String {
        switch decoded {
        case .identity: return "Add as contact"
        case .deviceLink: return "Pair this device"
        case .fastSetup: return "Use this setup code"
        default: return "Confirm"
        }
    }

    /// Best-effort relative description of expiry time. Past expiries should
    /// already be rejected by `FastSetupQrCode.decode` (it throws `.expired`),
    /// so this only formats a forward-looking duration.
    private func expiresInDescription(_ expiresAtUnixMs: Int64) -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let deltaSec = (expiresAtUnixMs - nowMs) / 1000
        if deltaSec < 0 { return "expired" }
        if deltaSec < 60 { return "in \(deltaSec)s" }
        if deltaSec < 3600 { return "in \(deltaSec / 60)m" }
        if deltaSec < 86400 { return "in \(deltaSec / 3600)h" }
        return "in \(deltaSec / 86400)d"
    }
}
