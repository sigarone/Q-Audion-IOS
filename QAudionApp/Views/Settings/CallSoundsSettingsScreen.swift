import SwiftUI
import Combine
import UIKit
import UniformTypeIdentifiers
import AVFoundation
import QAudionEngine

/// State and actions of the call-sounds screen. The ringtone id lives in the notifications blob of `SettingsStore`
/// (its `ringtoneId`), everything else in `CallSoundSettings`.
@MainActor
final class CallSoundsSettingsContainer: ObservableObject {

    /// An audio file picked by the user, copied into the temporary directory and waiting for the excerpt choice.
    struct PendingImport: Identifiable {
        let id = UUID()
        let url: URL
        let displayName: String
        let durationSeconds: Double
    }

    @Published private(set) var settings: CallSoundSettings
    @Published private(set) var ringtoneId: String
    @Published var notice: CustomRingtone.Notice?
    @Published var pendingImport: PendingImport?
    @Published private(set) var converting = false

    let preview: RingPreviewPlayer
    private let store: SettingsStore
    /// The imported file, copied to a temporary location while the excerpt is being chosen.
    private var pendingTempURL: URL?
    private var previewObserver: AnyCancellable?

    init(inCall: @escaping () -> Bool, store: SettingsStore = SettingsStore()) {
        self.store = store
        self.preview = RingPreviewPlayer(inCall: inCall)
        let stored = store.loadCallSounds()
        let id = store.loadNotifications().ringtoneId
        // A stored "custom" whose file is gone goes back to the default, with a note.
        let checked = CustomRingtone.reconcile(ringtoneId: id, settings: stored, customFileExists: CustomRingtone.customFileExists())
        self.settings = checked.settings
        self.ringtoneId = checked.ringtoneId
        // The rows show which preview is playing: forward the player's changes.
        previewObserver = preview.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if checked.notice != nil {
            self.notice = checked.notice
            persist(ringtoneId: checked.ringtoneId, settings: checked.settings)
        }
    }

    /// The id the list shows as selected: a legacy or unknown stored id shows as the default.
    var selectedId: String {
        CallSoundCatalog.resolve(ringtoneId: ringtoneId, customAvailable: CustomRingtone.customFileExists()).effectiveId
    }

    func selectBundled(_ id: String) {
        guard id == CallSoundCatalog.defaultRingtoneId || CallSoundCatalog.ringtoneIds.contains(id) else { return }
        notice = nil
        persist(ringtoneId: id, settings: settings)
    }

    func selectCustom() {
        guard CustomRingtone.customFileExists(), settings.customFileName != nil else { return }
        notice = nil
        persist(ringtoneId: CallSoundCatalog.customId, settings: settings)
    }

    func update(_ change: (inout CallSoundSettings) -> Void) {
        var next = settings
        change(&next)
        persist(ringtoneId: ringtoneId, settings: next)
    }

    private func persist(ringtoneId newId: String, settings newSettings: CallSoundSettings) {
        let oldId = ringtoneId
        settings = CallSoundSettings(
            ringVolume: newSettings.ringVolume, inCallVolume: newSettings.inCallVolume,
            connectionSoundEnabled: newSettings.connectionSoundEnabled, endSoundsEnabled: newSettings.endSoundsEnabled,
            ringHapticsEnabled: newSettings.ringHapticsEnabled, customFileName: newSettings.customFileName,
            customDisplayName: newSettings.customDisplayName, customStartSeconds: newSettings.customStartSeconds)
        ringtoneId = newId
        store.saveCallSounds(settings)
        let legacy = store.loadNotifications()
        store.saveNotifications(NotificationsSettingsViewModel(
            ringtoneId: newId, inAppSoundEnabled: legacy.inAppSoundEnabled, vibrationEnabled: legacy.vibrationEnabled,
            quietHours: legacy.quietHours, mutedContactsCount: legacy.mutedContactsCount))
        if oldId != newId || newId == CallSoundCatalog.customId {
            NotificationCenter.default.post(name: .qaudionCallRingtoneChanged, object: nil)
        }
    }

    // MARK: - Preview

    func previewBundled(_ id: String) {
        if preview.playingId == id { preview.stop(); return }
        let resolution = CallSoundCatalog.resolve(ringtoneId: id, customAvailable: false)
        preview.play(id: id, url: CallRingFiles.loopURL(resolution), volume: settings.ringVolume)
    }

    func previewCustom() {
        let id = CallSoundCatalog.customId
        if preview.playingId == id { preview.stop(); return }
        preview.play(id: id, url: CustomRingtone.customFileURL(), volume: settings.ringVolume)
    }

    // MARK: - Import

    /// Called with the URL chosen in the file picker. Copies the file out of the security scope first.
    func filePicked(_ result: Result<[URL], Error>) {
        preview.stop()
        guard case .success(let urls) = result, let picked = urls.first else { return }
        let access = picked.startAccessingSecurityScopedResource()
        defer { if access { picked.stopAccessingSecurityScopedResource() } }
        let bytes: Int = (try? picked.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard CustomRingtone.sourceSizeAllowed(bytes) else {
            finishImport(.failure(bytes > CustomRingtone.maxSourceBytes ? .tooLarge : .unreadable))
            return
        }
        let name = picked.deletingPathExtension().lastPathComponent
        let ext = picked.pathExtension
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ringsrc-" + UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
        do {
            try FileManager.default.copyItem(at: picked, to: temp)
        } catch {
            RTLog.warn("call", "ringimport copy=0")
            finishImport(.failure(.unreadable))
            return
        }
        pendingTempURL = temp
        Task { await self.inspect(temp, displayName: name) }
    }

    private func inspect(_ url: URL, displayName: String) async {
        do {
            let seconds = try await CustomRingtoneConverter.sourceDuration(of: url)
            pendingImport = PendingImport(url: url, displayName: displayName, durationSeconds: seconds)
        } catch let error as CustomRingtone.ImportError {
            discardTemp()
            finishImport(.failure(error))
        } catch {
            discardTemp()
            finishImport(.failure(.unreadable))
        }
    }

    private func discardTemp() {
        if let url = pendingTempURL { try? FileManager.default.removeItem(at: url) }
        pendingTempURL = nil
    }

    /// Closes the excerpt sheet without importing (its button, or a swipe down): stops the preview, drops the copy.
    func cancelImport() {
        preview.stop()
        discardTemp()
        pendingImport = nil
    }

    /// Converts the chosen excerpt and selects it; any failure falls back to the default ringtone with a note.
    func confirmImport(startSeconds: Double) {
        guard let pending = pendingImport, !converting, let destination = CustomRingtone.customFileURL() else { return }
        preview.stop()
        converting = true
        Task {
            let outcome: Result<CustomRingtone.ImportedFile, CustomRingtone.ImportError>
            do {
                _ = try await CustomRingtoneConverter.convert(source: pending.url, startSeconds: startSeconds, destination: destination)
                outcome = .success(CustomRingtone.ImportedFile(displayName: pending.displayName, startSeconds: startSeconds))
            } catch let error as CustomRingtone.ImportError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.unreadable)
            }
            discardTemp()
            pendingImport = nil
            converting = false
            finishImport(outcome)
        }
    }

    private func finishImport(_ outcome: Result<CustomRingtone.ImportedFile, CustomRingtone.ImportError>) {
        let selection = CustomRingtone.applyImport(
            outcome, settings: settings, ringtoneId: ringtoneId, previousCustomUsable: CustomRingtone.customFileExists())
        if case .failure(let error) = outcome {
            let line: String = "ringimport fail=" + error.rawValue
            RTLog.warn("call", line)
            // A failed import never removes the file that worked before; only a fallback with no usable file does.
            if selection.settings.customFileName == nil, let url = CustomRingtone.customFileURL() {
                try? FileManager.default.removeItem(at: url)
            }
        } else {
            RTLog.info("call", "ringimport ok=1")
        }
        notice = selection.notice
        persist(ringtoneId: selection.ringtoneId, settings: selection.settings)
    }
}

/// Settings, Notifications, "Suoni e avvisi di chiamata".
struct CallSoundsSettingsScreen: View {
    @StateObject private var container: CallSoundsSettingsContainer
    @State private var showPicker = false

    init(inCall: @escaping () -> Bool) {
        _container = StateObject(wrappedValue: CallSoundsSettingsContainer(inCall: inCall))
    }

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    private func loc(_ key: String.LocalizationValue) -> String { String(localized: key) }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ringtoneSection
                    volumeSection
                    cuesSection
                    vibrationSection
                    ledSection
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle(loc("Suoni e avvisi di chiamata"))
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            container.filePicked(result)
        }
        .sheet(item: $container.pendingImport, onDismiss: { container.cancelImport() }) { pending in
            CustomRingtoneExcerptSheet(container: container, pending: pending)
        }
        .onDisappear { container.preview.stop() }
    }

    // MARK: - Sections

    private var ringtoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(loc("Suoneria").uppercased())
            ringtoneRow(id: CallSoundCatalog.defaultRingtoneId, title: loc("Q-Audion (predefinita)"), subtitle: nil,
                        selected: container.selectedId == CallSoundCatalog.defaultRingtoneId,
                        select: { container.selectBundled(CallSoundCatalog.defaultRingtoneId) },
                        preview: { container.previewBundled(CallSoundCatalog.defaultRingtoneId) })
            ForEach(CallSoundCatalog.ringtoneIds, id: \.self) { id in
                ringtoneRow(id: id, title: ringtoneName(id), subtitle: nil, selected: container.selectedId == id,
                            select: { container.selectBundled(id) }, preview: { container.previewBundled(id) })
            }
            if container.settings.customFileName != nil, CustomRingtone.customFileExists() {
                let name = container.settings.customDisplayName ?? loc("Suoneria personalizzata")
                ringtoneRow(id: CallSoundCatalog.customId, title: name, subtitle: loc("Suoneria personalizzata"),
                            selected: container.selectedId == CallSoundCatalog.customId,
                            select: { container.selectCustom() }, preview: { container.previewCustom() })
            }
            Button { showPicker = true } label: {
                rowShell {
                    Image(systemName: "folder").font(.system(size: 17)).foregroundStyle(scheme.primary).frame(width: 22)
                    Text(loc("Da File…")).qaudionStyle(type.bodyMedium).foregroundStyle(scheme.onSurface)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if container.converting {
                Text(loc("Conversione in corso…")).qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant).padding(.horizontal, 14)
            }
            if let notice = container.notice {
                Text(noticeText(notice)).qaudionStyle(type.labelSmall).foregroundStyle(.orange).padding(.horizontal, 14)
            }
            Text(loc("Il file viene convertito sul telefono e se ne usano al massimo 30 secondi. Vanno bene mp3, m4a, wav e aiff. I file protetti da DRM, come i brani scaricati da Apple Music, non si possono usare."))
                .qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant).padding(.horizontal, 14)
            Text(loc("A telefono bloccato, se iOS non può usare il file, userà la sua suoneria di sistema."))
                .qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant).padding(.horizontal, 14)
        }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(loc("Volume").uppercased())
            sliderRow(title: loc("Volume suoneria"),
                      note: loc("Vale per la suoneria dentro l'app. Con il telefono bloccato vale il volume della suoneria di sistema."),
                      value: Binding(get: { Double(container.settings.ringVolume) },
                                     set: { newValue in container.update { $0.ringVolume = Float(newValue) } }))
            sliderRow(title: loc("Volume squillo in linea"),
                      note: loc("Il volume dello squillo e dei suoni che senti mentre chiami."),
                      value: Binding(get: { Double(container.settings.inCallVolume) },
                                     set: { newValue in container.update { $0.inCallVolume = Float(newValue) } }))
        }
    }

    private var cuesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(loc("Suoni della chiamata").uppercased())
            SettingsToggleRow(
                title: loc("Suono di connessione"),
                subtitle: loc("Suoni all'avvio e durante la connessione della chiamata"),
                isOn: Binding(get: { container.settings.connectionSoundEnabled },
                              set: { newValue in container.update { $0.connectionSoundEnabled = newValue } }))
            SettingsToggleRow(
                title: loc("Suoni di fine chiamata e occupato"),
                subtitle: loc("Il suono quando la chiamata finisce e il segnale di occupato"),
                isOn: Binding(get: { container.settings.endSoundsEnabled },
                              set: { newValue in container.update { $0.endSoundsEnabled = newValue } }))
        }
    }

    private var vibrationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(loc("Vibrazione").uppercased())
            SettingsToggleRow(
                title: loc("Vibrazione"),
                subtitle: loc("Vibra mentre suona la suoneria nell'app"),
                isOn: Binding(get: { container.settings.ringHapticsEnabled },
                              set: { newValue in container.update { $0.ringHapticsEnabled = newValue } }))
            openSettingsRow(title: loc("Vibrazione della suoneria di sistema"),
                            subtitle: loc("Si imposta nelle Impostazioni di iOS, in Suoni e feedback aptico"))
        }
    }

    private var ledSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(loc("Flash LED").uppercased())
            openSettingsRow(title: loc("Flash LED"),
                            subtitle: loc("Le app non possono controllare il flash LED. Attivalo in Impostazioni > Accessibilità > Audio e video > Flash LED per avvisi."))
        }
    }

    // MARK: - Rows

    private func ringtoneName(_ id: String) -> String {
        let first: String = String(id.prefix(1)).uppercased()
        let rest: String = String(id.dropFirst())
        return first + rest
    }

    private func noticeText(_ notice: CustomRingtone.Notice) -> String {
        switch notice {
        case .protectedContent: return loc("Il file è protetto da copia e non si può usare: è tornata la suoneria Q-Audion.")
        case .keptPrevious: return loc("Il file non si può usare (formato non supportato o protetto): resta la suoneria precedente.")
        case .conversionFailed: return loc("Non è stato possibile usare il file: è tornata la suoneria Q-Audion.")
        case .customUnavailable: return loc("Il file personalizzato non c'è più: è tornata la suoneria Q-Audion.")
        }
    }

    private func rowShell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 14) { content() }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surfaceVariant.opacity(0.4)))
    }

    private func ringtoneRow(id: String, title: String, subtitle: String?, selected: Bool,
                             select: @escaping () -> Void, preview: @escaping () -> Void) -> some View {
        let playing = container.preview.playingId == id
        return rowShell {
            Button(action: select) {
                HStack(spacing: 14) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17)).foregroundStyle(selected ? scheme.primary : scheme.onSurfaceVariant).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).qaudionStyle(type.bodyMedium).foregroundStyle(scheme.onSurface).lineLimit(1)
                        if let subtitle {
                            Text(subtitle).qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            Button(action: preview) {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 14)).foregroundStyle(scheme.onSurfaceVariant).frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? loc("Ferma anteprima") : loc("Anteprima"))
        }
    }

    private func sliderRow(title: String, note: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).qaudionStyle(type.bodyMedium).foregroundStyle(scheme.onSurface)
            Slider(value: value, in: 0...1)
            Text(note).qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(scheme.surfaceVariant.opacity(0.4)))
    }

    private func openSettingsRow(title: String, subtitle: String) -> some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
            rowShell {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).qaudionStyle(type.bodyMedium).foregroundStyle(scheme.onSurface)
                    Text(subtitle).qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square").font(.system(size: 14)).foregroundStyle(scheme.onSurfaceVariant)
            }
            .accessibilityHint(loc("Apri Impostazioni"))
        }
        .buttonStyle(.plain)
    }
}

/// Asks where the 30 s excerpt of a longer file starts, lets the user hear it, then converts.
struct CustomRingtoneExcerptSheet: View {
    @ObservedObject var container: CallSoundsSettingsContainer
    let pending: CallSoundsSettingsContainer.PendingImport
    @State private var start: Double = 0

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    private func loc(_ key: String.LocalizationValue) -> String { String(localized: key) }

    private var maxStart: Double { CustomRingtone.maxStart(sourceSeconds: pending.durationSeconds) }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let rest = total % 60
        return "\(minutes):" + (rest < 10 ? "0" : "") + "\(rest)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pending.displayName).qaudionStyle(type.bodyMedium).foregroundStyle(scheme.onSurface).lineLimit(2)
            if maxStart > 0 {
                Text(loc("Inizio dell'estratto") + ": " + clock(start) + " / " + clock(pending.durationSeconds))
                    .qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant)
                Slider(value: $start, in: 0...maxStart)
            } else {
                Text(loc("Il file dura meno di 30 secondi: si usa per intero."))
                    .qaudionStyle(type.labelSmall).foregroundStyle(scheme.onSurfaceVariant)
            }
            HStack(spacing: 12) {
                Button {
                    if container.preview.playingId == pending.id.uuidString {
                        container.preview.stop()
                    } else {
                        container.preview.play(id: pending.id.uuidString, url: pending.url, volume: container.settings.ringVolume, startAt: start)
                    }
                } label: {
                    Label(loc("Anteprima"), systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(loc("Annulla")) { container.cancelImport() }
                    .buttonStyle(.bordered)
                Button(loc("Usa questa suoneria")) { container.confirmImport(startSeconds: start) }
                    .buttonStyle(.borderedProminent)
                    .disabled(container.converting)
            }
            if container.converting {
                ProgressView(loc("Conversione in corso…"))
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(container.converting)
    }
}
