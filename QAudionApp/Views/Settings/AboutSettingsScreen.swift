import SwiftUI
import QAudionEngine
// W267: Mach syscalls (task_info, mach_task_basic_info) live in
// Darwin / Darwin.Mach. Foundation transitively imports Darwin on
// iOS but we make it explicit so the helper compiles cleanly.
import Darwin
// W282: AVAudioSession.recordPermission lives in AVFAudio
// (re-exported from AVFoundation, but we import directly to be
// explicit and avoid the linker reaching for QTKit on macOS).
#if canImport(AVFAudio)
import AVFAudio
#endif

@MainActor
final class AboutSettingsContainer: ObservableObject {
    @Published var viewModel: AboutSettingsViewModel
    init(initial: AboutSettingsViewModel = .mock) { self.viewModel = initial }
}

/// Read-only "Informazioni" screen. W26 design-token refactor: replaces
/// the iOS-native `Form { Section }` shell with the same dark editorial
/// vocabulary used in `SettingsScreen` (sectioned `surfaceVariant`-tinted
/// rows, `SettingsSectionHeader` titles, `extras.success`/`extras.riskHigh`
/// status colors). Functionally unchanged: same fields, same update
/// checker plumbing.
struct AboutSettingsScreen: View {
    @StateObject var container: AboutSettingsContainer
    @StateObject private var updateChecker: AppUpdateChecker
    /// W167: live WS connection state so the diagnostic status row
    /// updates in real time as connect / disconnect events fire.
    @ObservedObject private var appState: AppState

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    init(state: AppState) {
        self._container = StateObject(wrappedValue: AboutSettingsContainer())
        self._appState = ObservedObject(wrappedValue: state)
        _updateChecker = StateObject(wrappedValue: AppUpdateChecker(appState: state))
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("VERSIONE") {
                        kvRow("App", container.viewModel.appVersion, mono: false)
                        kvRow("Build", container.viewModel.buildNumber, mono: true)
                        // W297: tap the commit row to copy the SHA to
                        // clipboard. Useful when filing bug reports —
                        // tester can paste the canonical commit hash
                        // directly without copying from screenshots.
                        tapCopyRow("Commit", container.viewModel.gitCommitShort)
                        // W158: capture first-launch timestamp once,
                        // then surface it as "Membro da" so the user
                        // can see how long the app has been on this
                        // device. Stamped lazily via Self.firstSeen().
                        kvRow("Membro da", Self.firstSeenLabel(), mono: false)
                        // W162: per-build install timestamp — stamped
                        // when this specific build first launched.
                        // Lets the user know how long they've been
                        // running THIS version vs the older "Membro
                        // da" which spans the whole device install.
                        kvRow("Build installato",
                              Self.buildInstalledLabel(buildNumber: container.viewModel.buildNumber),
                              mono: false)
                        // W290: bundle metadata. CFBundleName is the
                        // app's display name as Apple sees it in iTC,
                        // CFBundleIdentifier is the canonical reverse-
                        // DNS id. W298: also tap-to-copy since these
                        // are the most commonly-copied IDs in bug
                        // reports.
                        tapCopyRow("Bundle name", Self.bundleDisplayName())
                        tapCopyRow("Bundle id", Self.bundleIdentifier())
                    }
                    section("PIATTAFORMA") {
                        kvRow("Target iOS", "iOS \(container.viewModel.iosDeploymentTarget)+", mono: true)
                        // W170: surface the runtime device + OS info
                        // so testers can quickly confirm what they're
                        // running on without leaving the app.
                        kvRow("Dispositivo", Self.deviceModelLabel(), mono: false)
                        kvRow("iOS in uso", Self.iosVersionLabel(), mono: true)
                        // W305: device idiom (phone / pad / mac via
                        // Catalyst). Useful when QA reports a layout
                        // bug — was it on iPhone or iPad? Idiom tells
                        // you immediately.
                        kvRow("Idiom", Self.idiomLabel(), mono: false)
                    }
                    // W264: live system telemetry. Useful for testers
                    // chasing performance regressions or thermal
                    // throttling during long voice/video calls. All
                    // values are read on each render — cheap (no I/O).
                    section("STATO SISTEMA") {
                        kvRow("Uptime processo", Self.processUptimeLabel(), mono: true)
                        kvRow("Stato termico", Self.thermalStateLabel(), mono: false)
                        kvRow("Core CPU disponibili", Self.processorCountLabel(), mono: true)
                        // W266: free disk space — useful when testers
                        // hit "upload failed" or cache eviction issues.
                        kvRow("Spazio libero", Self.availableDiskSpaceLabel(), mono: true)
                        // W267: resident memory usage of THIS process.
                        // PQC ops (ML-KEM-1024) + ONNX inference can be
                        // memory-heavy; visible footprint helps catch
                        // leaks during long sessions.
                        kvRow("Memoria processo", Self.residentMemoryLabel(), mono: true)
                        // W269: device locale identifier — surfaces
                        // mismatches between the app's hardcoded Italian
                        // strings and a user with en_US / de_DE etc.
                        // Useful when QA reports number formatting or
                        // pluralization quirks.
                        kvRow("Lingua sistema", Self.systemLocaleLabel(), mono: true)
                        // W300: region identifier separated from locale.
                        // Locale 'it_IT' splits into language=it + region=IT.
                        // Region drives default currency, calendar week
                        // start, etc. Useful when an Italian-speaking
                        // user has their region set to a non-Italy place
                        // (e.g. 'it_CH' — Italian in Switzerland).
                        kvRow("Regione", Self.regionLabel(), mono: true)
                        // W272: total physical memory of the device
                        // (not the app's quota). Gives context to the
                        // 'Memoria processo' row above — 84MB out of
                        // 4GB is fine; out of 1GB is concerning.
                        kvRow("Memoria fisica", Self.physicalMemoryLabel(), mono: true)
                        // W273: low-power mode status. iOS throttles
                        // CPU and reduces background activity when on;
                        // PQC keygen latency can spike noticeably.
                        kvRow("Risparmio energetico", Self.lowPowerLabel(), mono: false)
                        // W274: battery state + level. Useful when QA
                        // notices the app crashing on low battery
                        // (iOS aggressively reaps memory below 10%).
                        kvRow("Batteria", Self.batteryLabel(), mono: false)
                        // W275: screen brightness. Auto-brightness can
                        // make AASIST face/voice trust UI hard to read
                        // at low values; this is a quick check.
                        kvRow("Luminosità schermo", Self.brightnessLabel(), mono: true)
                        // W276: screen size + scale. Helps file an
                        // accurate bug report for layout regressions
                        // on smaller devices (iPhone SE, mini).
                        kvRow("Schermo", Self.screenSizeLabel(), mono: true)
                        // W279: device timezone — useful when QA
                        // reports timestamps that look 'off' (often a
                        // user just travelled across timezones).
                        kvRow("Fuso orario", Self.timeZoneLabel(), mono: true)
                        // W280: calendar identifier (e.g. 'gregorian',
                        // 'islamic-civil'). Some users have set their
                        // device to non-Gregorian; affects DateFormatter.
                        kvRow("Calendario", Self.calendarLabel(), mono: true)
                        // W281: dark/light mode preference. Lets QA
                        // confirm the design tokens are honoring the
                        // user's UITraitCollection at render time.
                        kvRow("Aspetto", Self.userInterfaceStyleLabel(), mono: false)
                        // W282: microphone permission status. Voice
                        // calls + voice notes rely on this; surfacing
                        // it helps testers confirm the prompt was
                        // accepted (or revoked).
                        kvRow("Permesso microfono", Self.microphonePermissionLabel(), mono: false)
                        // W286: audio session category. Voice calls
                        // need .playAndRecord; voice notes need
                        // .record; ringtone playback uses .playback.
                        // Helps debug 'mic stuck on' or 'audio routes
                        // to speakerphone unexpectedly' issues.
                        kvRow("Audio session", Self.audioSessionLabel(), mono: true)
                    }
                    // W159: local data summary — gives the user a
                    // sense of how much chat content lives on this
                    // device without exposing any peer content.
                    section("DATI LOCALI") {
                        let stats = Self.localDataStats()
                        kvRow("Conversazioni", "\(stats.conversations)", mono: true)
                        kvRow("Messaggi totali", "\(stats.messages)", mono: true)
                        kvRow("Abbozzi salvati", "\(stats.drafts)", mono: true)
                        // W277: identifierForVendor. UUID stable across
                        // launches as long as the user has at least one
                        // app from the same vendor installed. Resets on
                        // full reinstall. Different from auth token /
                        // device-id (those are server-issued).
                        // W298: tap-to-copy for the truncated UUID
                        // prefix (lets QA include it in bug reports).
                        tapCopyRow("ID dispositivo (vendor)", Self.vendorIdLabel())
                    }
                    // W311: STATISTICHE section celebrating v1.0.300
                    // milestone. Surfaces meta-data about the app's
                    // release cadence + the user's relationship with
                    // it. Cheap reads — just dictionary lookups.
                    section("STATISTICHE") {
                        kvRow("Release nel changelog",
                              Self.changelogReleaseCountLabel(),
                              mono: true)
                        kvRow("Giorni dall'installazione",
                              Self.daysSinceFirstSeenLabel(),
                              mono: true)
                        kvRow("Build identificativo",
                              Self.totalKnownBuildsLabel(),
                              mono: true)
                    }
                    section("SICUREZZA") {
                        statusRow("ML-KEM-1024 (PQC)",
                                  enabled: container.viewModel.mlKem1024Enabled)
                        kvRow("ONNX Runtime", container.viewModel.onnxruntimeVersion, mono: true)
                    }
                    // W167: live WebSocket connection state. Helps QA
                    // confirm whether the server-side leg is healthy
                    // without opening Diagnostics export.
                    section("CONNESSIONE") {
                        kvRow("WebSocket",
                              appState.wsConnectionState.rawValue,
                              mono: true)
                        kvRow("Autenticato",
                              appState.isAuthenticated ? "sì" : "no",
                              mono: false)
                    }
                    section("AGGIORNAMENTI") {
                        updateBlock
                    }
                    // W173: 1-tap mailto to support — pre-fills the
                    // subject with the build identifier so triage is
                    // faster. Plain UIApplication.shared.open call.
                    section("ASSISTENZA") {
                        Button {
                            #if canImport(UIKit)
                            let v = container.viewModel.appVersion
                            let b = container.viewModel.buildNumber
                            let subject = "Q-Audion v\(v) (build \(b)) — segnalazione"
                            let encoded = subject
                                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                            if let url = URL(string: "mailto:support@qaudion.app?subject=" + encoded) {
                                UIApplication.shared.open(url)
                            }
                            #endif
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "envelope.fill")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundStyle(scheme.primary)
                                    .frame(width: 22)
                                Text("Contatta supporto")
                                    .qaudionStyle(type.bodyMedium)
                                    .foregroundStyle(scheme.onSurface)
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundStyle(scheme.onSurfaceVariant)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(scheme.surfaceVariant.opacity(0.4))
                            )
                        }
                        .buttonStyle(.plain)

                        // W291: open the public Q-Audion-IOS GitHub
                        // repo in browser. Useful for testers who want
                        // to see release tags / commit history /
                        // CHANGELOG without leaving the app.
                        Button {
                            #if canImport(UIKit)
                            let url = URL(string: "https://github.com/sigarone/Q-Audion-IOS/tags")
                            if let u = url {
                                UIApplication.shared.open(u)
                            }
                            #endif
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundStyle(scheme.primary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Tags GitHub")
                                        .qaudionStyle(type.bodyMedium)
                                        .foregroundStyle(scheme.onSurface)
                                    Text("Cronologia release pubblica del progetto")
                                        .qaudionStyle(type.labelSmall)
                                        .foregroundStyle(scheme.onSurfaceVariant)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundStyle(scheme.onSurfaceVariant)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(scheme.surfaceVariant.opacity(0.4))
                            )
                        }
                        .buttonStyle(.plain)

                        // W288: open TestFlight feedback URL in browser.
                        // The standard public TestFlight feedback URL
                        // for an app uses the App Apple ID; ours is
                        // 6762266299 (see ios-testflight.yml's APP_APPLE_ID).
                        Button {
                            #if canImport(UIKit)
                            // Hardcode the public feedback URL since
                            // the App Apple ID is stable.
                            let url = URL(string: "https://testflight.apple.com/v1/app/6762266299")
                            if let u = url {
                                UIApplication.shared.open(u)
                            }
                            #endif
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "ant.fill")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundStyle(scheme.primary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Feedback TestFlight")
                                        .qaudionStyle(type.bodyMedium)
                                        .foregroundStyle(scheme.onSurface)
                                    Text("Apri pagina pubblica del beta")
                                        .qaudionStyle(type.labelSmall)
                                        .foregroundStyle(scheme.onSurfaceVariant)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundStyle(scheme.onSurfaceVariant)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(scheme.surfaceVariant.opacity(0.4))
                            )
                        }
                        .buttonStyle(.plain)

                        // W179: copy a compact build-ID blob (version,
                        // build, device, iOS) to the clipboard so testers
                        // can paste it into any chat / issue tracker
                        // without opening Mail. Sister to "Contatta
                        // supporto" — same data, different transport.
                        Button {
                            #if canImport(UIKit)
                            let v = container.viewModel.appVersion
                            let b = container.viewModel.buildNumber
                            let device = Self.deviceModelLabel()
                            let ios = Self.iosVersionLabel()
                            // W179: single-segment + concatenation only.
                            // See CLAUDE.md §13 — no multi-segment
                            // interpolation inside the closure.
                            let line: String =
                                "Q-Audion v" + v + " (build " + b + ") · "
                                + device + " · " + ios
                            UIPasteboard.general.string = line
                            #endif
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "doc.on.doc.fill")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundStyle(scheme.primary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Copia diagnostica rapida")
                                        .qaudionStyle(type.bodyMedium)
                                        .foregroundStyle(scheme.onSurface)
                                    Text("Versione · build · dispositivo · iOS")
                                        .qaudionStyle(type.labelSmall)
                                        .foregroundStyle(scheme.onSurfaceVariant)
                                }
                                Spacer()
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundStyle(scheme.onSurfaceVariant)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(scheme.surfaceVariant.opacity(0.4))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Informazioni")
    }

    // MARK: - Section wrapper

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        SettingsSectionHeader(title)
        VStack(spacing: 8) {
            content()
        }
    }

    /// W159: local data stats. Walks the in-memory UserDefaults
    /// dictionary to count conversations / messages / drafts. Cheap
    /// — no disk I/O beyond the initial defaults plist load.
    private struct LocalDataStats {
        let conversations: Int
        let messages: Int
        let drafts: Int
    }

    private static func localDataStats() -> LocalDataStats {
        let store = UserDefaults.standard
        let allKeys = store.dictionaryRepresentation().keys
        let convKey = "qaudion.conv.list"
        let msgPrefix = "qaudion.conv.msgs."
        let draftPrefix = "qaudion.composer.draft."

        // Conversations are persisted as a single JSON array under
        // qaudion.conv.list — count its elements if available.
        var conversations = 0
        if let data = store.data(forKey: convKey),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            conversations = arr.count
        }

        var messages = 0
        for k in allKeys where k.hasPrefix(msgPrefix) {
            if let data = store.data(forKey: k),
               let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
                messages += arr.count
            }
        }

        var drafts = 0
        for k in allKeys where k.hasPrefix(draftPrefix) { drafts += 1 }

        return LocalDataStats(conversations: conversations,
                              messages: messages, drafts: drafts)
    }

    /// W290: app's display name from Info.plist CFBundleName. Distinct
    /// from `CFBundleDisplayName` (which iOS uses for the home-screen
    /// label); CFBundleName is the bare app name.
    private static func bundleDisplayName() -> String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return name ?? "?"
    }

    /// W290: bundle identifier (e.g. "com.qaudion.app"). Reverse-DNS
    /// canonical id. Mostly stable across builds; surfaces drift if
    /// ever changed.
    private static func bundleIdentifier() -> String {
        return Bundle.main.bundleIdentifier ?? "?"
    }

    /// W311: count of release entries in the in-app changelog. Reads
    /// from ReleaseNote.releaseNotes.count — the data file (W302).
    private static func changelogReleaseCountLabel() -> String {
        return String(ReleaseNote.releaseNotes.count) + " entries"
    }

    /// W311: days since first launch on this device. Reuses the
    /// same first-seen stamp as W158 'Membro da'. Static helper
    /// that recomputes on each render (cheap — UserDefaults read +
    /// arithmetic).
    private static func daysSinceFirstSeenLabel() -> String {
        let key = "qaudion.firstSeen"
        let store = UserDefaults.standard
        let firstSeen: Date = (store.object(forKey: key) as? Date) ?? Date()
        let elapsed: TimeInterval = Date().timeIntervalSince(firstSeen)
        let days: Int = Int(elapsed / 86400.0)
        if days == 0 { return "Oggi" }
        if days == 1 { return "1 giorno" }
        return String(days) + " giorni"
    }

    /// W311: count of distinct build numbers that have been launched
    /// on this device. Walks UserDefaults for the qaudion.buildSeen.
    /// prefix — each build gets its own stamp via W162.
    private static func totalKnownBuildsLabel() -> String {
        let prefix = "qaudion.buildSeen."
        let store = UserDefaults.standard
        let allKeys = store.dictionaryRepresentation().keys
        var n = 0
        for k in allKeys where k.hasPrefix(prefix) { n += 1 }
        if n == 0 { return "—" }
        if n == 1 { return "1 build" }
        return String(n) + " build"
    }

    /// W170: device model label for the PIATTAFORMA row.
    /// UIDevice.current.model returns generic "iPhone" / "iPad" — the
    /// hardware identifier (e.g. iPhone15,4) lives under sysctl, but
    /// the user-friendly model name is enough here.
    private static func deviceModelLabel() -> String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "?"
        #endif
    }

    /// W305: friendly label for UIUserInterfaceIdiom. Following the
    /// W289 pattern, use a regular `default` instead of @unknown
    /// default — Xcode 26.4 strict mode treats that as exhaustive
    /// even when the SDK adds new cases (.vision in iOS 17+).
    private static func idiomLabel() -> String {
        #if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:        return "iPhone"
        case .pad:          return "iPad"
        case .mac:          return "Mac (Catalyst)"
        case .tv:           return "Apple TV"
        case .carPlay:      return "CarPlay"
        case .unspecified:  return "?"
        default:            return "Altro"
        }
        #else
        return "?"
        #endif
    }

    /// W170: running iOS version (UIDevice.current.systemVersion).
    private static func iosVersionLabel() -> String {
        #if canImport(UIKit)
        return "iOS " + UIDevice.current.systemVersion
        #else
        return "?"
        #endif
    }

    /// W264: process uptime as a short Italian label, e.g. "3h 12m"
    /// or "47s". Computed from ProcessInfo.systemUptime which is the
    /// device's monotonic uptime — we anchor on
    /// StaticUptimeAnchor.processStartedAt for a real process timer.
    /// Done as a static helper to keep the call-site interpolation
    /// out of the SwiftUI body. See CLAUDE.md §13.
    private static func processUptimeLabel() -> String {
        // processStartedAt is a snapshot of ProcessInfo.systemUptime at
        // process-launch — both endpoints are TimeIntervals on the same
        // monotonic clock, so subtraction gives elapsed seconds.
        let now: TimeInterval = ProcessInfo.processInfo.systemUptime
        let elapsed: TimeInterval = now - StaticUptimeAnchor.processStartedAt
        let secs = Int(elapsed)
        if secs < 60 { return String(secs) + "s" }
        let mins = secs / 60
        if mins < 60 { return String(mins) + "m " + String(secs % 60) + "s" }
        let hours = mins / 60
        return String(hours) + "h " + String(mins % 60) + "m"
    }

    /// W264: thermal state as a friendly Italian label. The .nominal
    /// state is normal; .fair / .serious / .critical indicate the
    /// device is throttling. Useful when testers report calls dropping
    /// quality after a few minutes — could be thermal-related.
    private static func thermalStateLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "Normale"
        case .fair:     return "Tiepido"
        case .serious:  return "Caldo"
        case .critical: return "Critico"
        @unknown default: return "Sconosciuto"
        }
    }

    /// W264: number of activeProcessors (the CPU cores currently
    /// available to user-space — system services may have parked some).
    private static func processorCountLabel() -> String {
        return String(ProcessInfo.processInfo.activeProcessorCount)
    }

    /// W269: device locale identifier (e.g. "it_IT", "en_US"). Reads
    /// from `Locale.current.identifier`. Static + single-statement to
    /// keep type-checker scope clean.
    private static func systemLocaleLabel() -> String {
        return Locale.current.identifier
    }

    /// W300: region identifier (e.g. "IT", "CH", "US"). Falls back to
    /// the locale's regionCode if the iOS 16+ `Locale.Region` API
    /// surfaces nil. Static helper, no closures.
    private static func regionLabel() -> String {
        if #available(iOS 16.0, *) {
            if let region = Locale.current.region {
                return region.identifier
            }
        }
        // Fallback for completeness — pre-iOS 16 / unset region.
        return Locale.current.region?.identifier ?? "?"
    }

    /// W272: total physical memory in GB, formatted like "6,00 GB" via
    /// Italian locale. ProcessInfo.physicalMemory returns bytes (UInt64).
    private static func physicalMemoryLabel() -> String {
        let bytes: UInt64 = ProcessInfo.processInfo.physicalMemory
        let gb: Double = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        let nf = NumberFormatter()
        nf.locale = Locale(identifier: "it_IT")
        nf.minimumFractionDigits = 2
        nf.maximumFractionDigits = 2
        let formatted: String = nf.string(from: NSNumber(value: gb)) ?? "?"
        return formatted + " GB"
    }

    /// W273: low-power mode status as a friendly Italian label. iOS
    /// throttles CPU + reduces background activity when this is on,
    /// which can spike PQC keygen latency by 30-60%.
    private static func lowPowerLabel() -> String {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return "Attivo (CPU ridotta)"
        } else {
            return "Disattivato"
        }
    }

    /// W274: battery state + level. UIDevice requires
    /// `isBatteryMonitoringEnabled = true` to populate these — set
    /// once on first read here. Format: "78% · In carica" or
    /// "12% · Scarica".
    private static func batteryLabel() -> String {
        #if canImport(UIKit)
        let dev = UIDevice.current
        if !dev.isBatteryMonitoringEnabled {
            dev.isBatteryMonitoringEnabled = true
        }
        let level = dev.batteryLevel
        let pct: String
        if level < 0 {
            pct = "?"
        } else {
            pct = String(Int(level * 100.0)) + "%"
        }
        let stateText: String
        switch dev.batteryState {
        case .charging:   stateText = "In carica"
        case .full:       stateText = "Piena"
        case .unplugged:  stateText = "Scarica"
        case .unknown:    stateText = "Sconosciuto"
        @unknown default: stateText = "?"
        }
        return pct + " · " + stateText
        #else
        return "?"
        #endif
    }

    /// W275: screen brightness 0..1 → "47%" string. Reads from
    /// UIScreen.main.brightness which is the auto-brightness adjusted
    /// value, not the system setting slider.
    private static func brightnessLabel() -> String {
        #if canImport(UIKit)
        let value: Double = Double(UIScreen.main.brightness)
        let pct: Int = Int((value * 100.0).rounded())
        return String(pct) + "%"
        #else
        return "?"
        #endif
    }

    /// W277: identifierForVendor as a short truncated UUID, e.g.
    /// "5C9F4E2A…". Full UUID is too long for a kvRow; the prefix is
    /// enough to correlate when triaging. Resets on full app reinstall
    /// (when no other apps from the same vendor are installed).
    private static func vendorIdLabel() -> String {
        #if canImport(UIKit)
        guard let uuid = UIDevice.current.identifierForVendor else {
            return "?"
        }
        let full: String = uuid.uuidString
        // Take the first 8 chars + ellipsis for a compact display.
        if full.count > 9 {
            let head = String(full.prefix(8))
            return head + "…"
        }
        return full
        #else
        return "?"
        #endif
    }

    /// W276: screen size + native scale. e.g. "390×844 · @3x". The
    /// width/height are in points (logical pixels); native scale tells
    /// you how many physical pixels per point.
    private static func screenSizeLabel() -> String {
        #if canImport(UIKit)
        let bounds = UIScreen.main.bounds
        let scale: Int = Int(UIScreen.main.nativeScale)
        let w: Int = Int(bounds.width)
        let h: Int = Int(bounds.height)
        // Build via concat — see CLAUDE.md §13 (no multi-segment
        // interpolations even outside closures, defensive habit).
        return String(w) + "×" + String(h) + " · @" + String(scale) + "x"
        #else
        return "?"
        #endif
    }

    /// W279: timezone identifier (e.g. "Europe/Rome"). Single-statement
    /// helper that pulls from TimeZone.current.
    private static func timeZoneLabel() -> String {
        return TimeZone.current.identifier
    }

    /// W280: calendar identifier (e.g. "gregorian", "islamic-civil").
    /// Affects all DateFormatter output across the app.
    private static func calendarLabel() -> String {
        // W289: in Xcode 26.4 strict mode @unknown default isn't
        // enough for Calendar.Identifier (the SDK added new cases
        // like .dangi). Use a regular default to make it exhaustive.
        let id = Calendar.current.identifier
        switch id {
        case .gregorian:        return "Gregoriano"
        case .buddhist:         return "Buddista"
        case .chinese:          return "Cinese"
        case .coptic:           return "Copto"
        case .ethiopicAmeteAlem: return "Etiope (Amete Alem)"
        case .ethiopicAmeteMihret: return "Etiope (Amete Mihret)"
        case .hebrew:           return "Ebraico"
        case .iso8601:          return "ISO 8601"
        case .indian:           return "Indiano"
        case .islamic:          return "Islamico"
        case .islamicCivil:     return "Islamico civile"
        case .japanese:         return "Giapponese"
        case .persian:          return "Persiano"
        case .republicOfChina:  return "Repubblica di Cina"
        case .islamicTabular:   return "Islamico tabulare"
        case .islamicUmmAlQura: return "Islamico (Umm al-Qura)"
        default:                return "Sconosciuto"
        }
    }

    /// W281: user interface style (light / dark / unspecified).
    /// Reads from UIScreen.main.traitCollection. Note: at the View
    /// level @Environment(\.colorScheme) is the canonical path, but
    /// for a one-off About row this is simpler and works.
    private static func userInterfaceStyleLabel() -> String {
        #if canImport(UIKit)
        switch UIScreen.main.traitCollection.userInterfaceStyle {
        case .light:    return "Chiaro"
        case .dark:     return "Scuro"
        case .unspecified: return "Non specificato"
        @unknown default: return "Sconosciuto"
        }
        #else
        return "?"
        #endif
    }

    /// W282: microphone permission state. Voice calls + W72 voice
    /// notes rely on this; surfacing helps testers verify the prompt
    /// was actually accepted (or revoked from iOS Settings later).
    private static func microphonePermissionLabel() -> String {
        #if canImport(AVFAudio)
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:    return "Concesso"
        case .denied:     return "Negato"
        case .undetermined: return "Non richiesto"
        @unknown default: return "Sconosciuto"
        }
        #else
        return "?"
        #endif
    }

    /// W286: current audio session category. AVAudioSession exposes
    /// `category` as `AVAudioSession.Category` enum-like constant.
    /// Friendly label format: "playAndRecord" or "playback" etc.
    private static func audioSessionLabel() -> String {
        #if canImport(AVFAudio)
        let cat = AVAudioSession.sharedInstance().category
        // .rawValue is e.g. "AVAudioSessionCategoryPlayAndRecord";
        // strip the prefix for a friendly short name.
        let raw: String = cat.rawValue
        let prefix: String = "AVAudioSessionCategory"
        if raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count))
        }
        return raw
        #else
        return "?"
        #endif
    }

    /// W267: resident memory of the current process, formatted as
    /// "84,3 MB" (Italian decimal-comma) or "?". Uses
    /// mach_task_basic_info via the task_info() Mach syscall; the
    /// resident_size field is the same number Activity Monitor and
    /// Instruments report as "Memory". Cheap (no allocation, single
    /// syscall). Static + single-statement-like to keep type-checker
    /// happy. See CLAUDE.md §13.
    private static func residentMemoryLabel() -> String {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.stride
                / MemoryLayout<natural_t>.stride
        )
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          reb,
                          &count)
            }
        }
        guard kr == KERN_SUCCESS else { return "?" }
        let mb: Double = Double(info.resident_size) / (1024.0 * 1024.0)
        // Italian decimal-comma formatting via NumberFormatter; avoids
        // locale-shenanigans of String(format:) which uses the user's
        // active locale (could be en_US in some sims).
        let nf = NumberFormatter()
        nf.locale = Locale(identifier: "it_IT")
        nf.minimumFractionDigits = 1
        nf.maximumFractionDigits = 1
        let formatted: String = nf.string(from: NSNumber(value: mb)) ?? "?"
        return formatted + " MB"
    }

    /// W266: free disk space label, e.g. "12,4 GB liberi" or "?".
    /// Uses .volumeAvailableCapacityForImportantUsage which honors
    /// iOS's purgeable-cache reservation — gives testers the realistic
    /// number for "how much can my app actually grow into" not the
    /// absolute filesystem free space. Italian locale formatting.
    private static func availableDiskSpaceLabel() -> String {
        let fm = FileManager.default
        guard let docs = try? fm.url(for: .documentDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: false) else {
            return "?"
        }
        let keys: [URLResourceKey] = [.volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? docs.resourceValues(forKeys: Set(keys)),
              let bytes = values.volumeAvailableCapacityForImportantUsage else {
            return "?"
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .decimal
        // W289: ByteCountFormatter has no `locale` property in iOS
        // Foundation — it derives formatting from the system locale
        // automatically. Removed the bogus assignment.
        let formatted: String = formatter.string(fromByteCount: Int64(bytes))
        return formatted + " liberi"
    }

    /// W162: stamp the first-launch timestamp for THIS build number
    /// (so Settings can show "Build installato 3 giorni fa"). Keyed
    /// by `qaudion.buildSeen.<n>` so each build gets its own stamp.
    /// Format: relative time-ago in Italian.
    private static func buildInstalledLabel(buildNumber: String) -> String {
        let key = "qaudion.buildSeen." + buildNumber
        let store = UserDefaults.standard
        let date: Date = {
            if let prior = store.object(forKey: key) as? Date {
                return prior
            }
            let now = Date()
            store.set(now, forKey: key)
            return now
        }()
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "ora" }
        if elapsed < 3600 {
            let m = Int(elapsed / 60)
            return m == 1 ? "1 minuto fa" : "\(m) minuti fa"
        }
        if elapsed < 86400 {
            let h = Int(elapsed / 3600)
            return h == 1 ? "1 ora fa" : "\(h) ore fa"
        }
        let d = Int(elapsed / 86400)
        return d == 1 ? "1 giorno fa" : "\(d) giorni fa"
    }

    private static let aboutDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// W158: read or stamp the first-launch timestamp under
    /// `qaudion.firstSeen`. Idempotent — only writes the value the
    /// first time this helper runs on a given device.
    private static func firstSeenLabel() -> String {
        let key = "qaudion.firstSeen"
        let store = UserDefaults.standard
        let date: Date = {
            if let prior = store.object(forKey: key) as? Date {
                return prior
            }
            let now = Date()
            store.set(now, forKey: key)
            return now
        }()
        return aboutDateFormatter.string(from: date)
    }

    // MARK: - Rows

    private func kvRow(_ label: String, _ value: String, mono: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .modifier(MonoIfNeeded(mono: mono))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    /// W297: kvRow variant with tap-to-copy. Identical visuals plus a
    /// faint clipboard icon trailing the value to telegraph the gesture.
    /// Tapping copies `value` to UIPasteboard and shows haptic feedback.
    /// Mono-formatted (since copyable values are usually IDs / hashes).
    private func tapCopyRow(_ label: String, _ value: String) -> some View {
        TapCopyRow(label: label, value: value)
    }

    private func statusRow(_ label: String, enabled: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(enabled ? extras.success : extras.riskHigh)
                    .frame(width: 8, height: 8)
                Text(enabled ? "Attivo" : "Disattivo")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(enabled ? extras.success : extras.riskHigh)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    // MARK: - Updates block

    @ViewBuilder
    private var updateBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result = updateChecker.lastResult {
                switch result {
                case .noUpdate:
                    iconRow(icon: "checkmark.circle.fill",
                            tint: extras.success,
                            title: "Sei aggiornato all'ultima versione",
                            subtitle: nil)
                case .updateAvailable(let info):
                    VStack(alignment: .leading, spacing: 8) {
                        iconRow(icon: "arrow.down.circle.fill",
                                tint: scheme.primary,
                                title: "Aggiornamento disponibile: v\(info.availableVersion)",
                                subtitle: info.releaseNotes.isEmpty ? nil : info.releaseNotes)
                        if info.downloadUrl != nil {
                            Button { updateChecker.openAppStoreLink(for: info) } label: {
                                Text("Apri App Store")
                                    .qaudionStyle(type.labelLarge)
                                    .foregroundStyle(scheme.onPrimary)
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                                    .background(Capsule().fill(scheme.primary))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                case .error(let msg):
                    iconRow(icon: "exclamationmark.triangle.fill",
                            tint: extras.warning,
                            title: msg,
                            subtitle: nil)
                }
            }

            if let last = updateChecker.lastChecked {
                Text("Ultimo controllo \(last.formatted(.relative(presentation: .named)))")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }

            Button {
                Task { await updateChecker.checkForUpdates() }
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise.circle")
                    Text("Controlla aggiornamenti")
                        .qaudionStyle(type.labelLarge)
                    if updateChecker.isChecking {
                        Spacer()
                        ProgressView().scaleEffect(0.8).tint(scheme.onSurface)
                    }
                }
                .foregroundStyle(scheme.onSurface)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(scheme.surfaceVariant.opacity(0.4))
                )
            }
            .buttonStyle(.plain)
            .disabled(updateChecker.isChecking)
        }
    }

    private func iconRow(icon: String,
                         tint: Color,
                         title: String,
                         subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                if let subtitle {
                    Text(subtitle)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }
}

private struct MonoIfNeeded: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}
