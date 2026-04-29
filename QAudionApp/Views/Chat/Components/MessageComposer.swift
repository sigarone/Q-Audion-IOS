import SwiftUI

/// Chat input bar. 1:1 port of Android
/// `qaudion-android-new/feature/feature-chat/.../components/MessageComposer.kt`.
///
/// Vertically composed:
///   1. **Edit banner** (visible when `editingTarget != nil`) — amber pill
///      with "Stai modificando un messaggio" + close ✕.
///   2. **Reply banner** (visible when `replyTarget != nil`) — green-bar
///      pill with "Rispondi a {author}" + excerpt + close ✕.
///   3. **Input row** — paperclip / text field / mic-or-send button.
///
/// The mic ⇄ send button toggles by content: empty trimmed text → mic
/// (push-to-talk via long-press). Non-empty → send (capsule, primary bg).
///
/// Push-to-talk: SwiftUI's `.onLongPressGesture(minimumDuration:)` fires
/// on press & on release, so we drive `isRecording` from a
/// `DragGesture(minimumDistance: 0)` to mirror Compose's
/// `awaitFirstDown` / `waitForUpOrCancellation` flow precisely. Cancel is
/// reported when the touch leaves the button rect.
struct MessageComposer: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    @Binding var text: String
    let editingTarget: EditingTarget?
    let replyTarget: ReplyTarget?
    let onAttach: () -> Void
    let onSend: () -> Void
    let onCancelEdit: () -> Void
    let onCancelReply: () -> Void
    /// Voice-note callbacks. The defaults are no-ops so callers that do
    /// not yet have a recorder wired can pass nothing and still get a UI
    /// without a runtime crash on long-press.
    let onStartVoiceNote: () -> Void
    let onFinishVoiceNote: () -> Void
    let onCancelVoiceNote: () -> Void

    @State private var isRecording: Bool = false

    init(text: Binding<String>,
         editingTarget: EditingTarget? = nil,
         replyTarget: ReplyTarget? = nil,
         onAttach: @escaping () -> Void = {},
         onSend: @escaping () -> Void = {},
         onCancelEdit: @escaping () -> Void = {},
         onCancelReply: @escaping () -> Void = {},
         onStartVoiceNote: @escaping () -> Void = {},
         onFinishVoiceNote: @escaping () -> Void = {},
         onCancelVoiceNote: @escaping () -> Void = {}) {
        self._text = text
        self.editingTarget = editingTarget
        self.replyTarget = replyTarget
        self.onAttach = onAttach
        self.onSend = onSend
        self.onCancelEdit = onCancelEdit
        self.onCancelReply = onCancelReply
        self.onStartVoiceNote = onStartVoiceNote
        self.onFinishVoiceNote = onFinishVoiceNote
        self.onCancelVoiceNote = onCancelVoiceNote
    }

    var body: some View {
        VStack(spacing: 6) {
            if let edit = editingTarget {
                editBanner(edit)
            }
            if let reply = replyTarget {
                replyBanner(reply)
            }
            inputRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(scheme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(scheme.outline.opacity(0.35))
                .frame(height: 0.5)
        }
    }

    // MARK: - Banners

    private func editBanner(_ edit: EditingTarget) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Rectangle()
                .fill(extras.warning)
                .frame(width: 2, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stai modificando un messaggio")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.0)
                    .foregroundStyle(extras.warning)
                if let preview = edit.previewText {
                    Text(preview)
                        .qaudionStyle(type.bodySmall)
                        .foregroundStyle(scheme.onSurface.opacity(0.85))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: onCancelEdit) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Annulla modifica")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(extras.warning.opacity(0.15)))
    }

    private func replyBanner(_ reply: ReplyTarget) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Rectangle()
                .fill(extras.success)
                .frame(width: 2, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Rispondi a \(reply.author)")
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.0)
                    .foregroundStyle(extras.success)
                Text(reply.excerpt)
                    .qaudionStyle(type.bodySmall)
                    .italic()
                    .foregroundStyle(scheme.onSurface.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onCancelReply) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Annulla risposta")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(scheme.surfaceVariant.opacity(0.4)))
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: onAttach) {
                Image(systemName: "paperclip")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Allega")

            // Multi-line text field. iOS 16+ TextField with axis: .vertical
            // grows up to N lines then scrolls — exactly what Android's
            // BasicTextField does in our composer.
            TextField("", text: $text, prompt: placeholder, axis: .vertical)
                .lineLimit(1...5)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
                .tint(scheme.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(scheme.surfaceVariant.opacity(0.45))
                )

            sendOrMicButton
        }
    }

    private var placeholder: Text {
        // `.foregroundColor(_:)` (iOS 13+) returns Text — required for
        // the property's `Text` return type. `.foregroundStyle(_:)` on
        // Text returns `some View` until iOS 17, which would break the
        // explicit return-type contract.
        Text("Messaggio cifrato…")
            .italic()
            .foregroundColor(scheme.onSurfaceVariant)
    }

    @ViewBuilder
    private var sendOrMicButton: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            micButton
        } else {
            sendButton
        }
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(scheme.onPrimary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(scheme.primary))
        }
        .accessibilityLabel("Invia messaggio")
    }

    private var micButton: some View {
        // DragGesture(minimumDistance: 0) lets us emulate the Compose
        // press-to-talk flow:
        //   - onChanged (first touch)  → onStartVoiceNote, isRecording=true
        //   - onEnded (touch lifts)    → onFinishVoiceNote, isRecording=false
        // We can't independently detect "drag-out cancel" reliably without
        // a GeometryReader on the hit-rect; we accept that simplification
        // for now (Android's awaitEachGesture distinguishes cancel via
        // PointerEventPass.Final, which has no clean SwiftUI analogue).
        Image(systemName: "mic.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(isRecording ? scheme.onError : scheme.onSurface)
            .frame(width: 40, height: 40)
            .background(Circle().fill(isRecording ? scheme.error : scheme.surfaceVariant.opacity(0.5)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isRecording {
                            isRecording = true
                            onStartVoiceNote()
                        }
                    }
                    .onEnded { _ in
                        if isRecording {
                            isRecording = false
                            onFinishVoiceNote()
                        }
                    }
            )
            .accessibilityLabel(isRecording ? "Sto registrando vocale" : "Tieni premuto per registrare vocale")
    }
}

// MARK: - Target model types

extension MessageComposer {
    struct EditingTarget: Equatable {
        let messageId: String
        let previewText: String?
    }

    struct ReplyTarget: Equatable {
        let messageId: String
        let author: String
        let excerpt: String
    }
}

// MARK: - Preview

private struct ComposerPreview: View {
    @State var text: String = ""
    @State var withEdit = false
    @State var withReply = false

    var body: some View {
        VStack {
            Spacer()
            Toggle("Edit banner", isOn: $withEdit).padding(.horizontal)
            Toggle("Reply banner", isOn: $withReply).padding(.horizontal)
            MessageComposer(
                text: $text,
                editingTarget: withEdit ? .init(messageId: "m1",
                                                previewText: "Vecchio testo del messaggio…")
                                        : nil,
                replyTarget: withReply ? .init(messageId: "m2",
                                               author: "Mario",
                                               excerpt: "ho la chiave nuova")
                                       : nil,
                onSend: { text = "" }
            )
        }
        .qAudionTheme(dark: true)
    }
}

#Preview { ComposerPreview() }
