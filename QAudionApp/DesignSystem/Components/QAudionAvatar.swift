import SwiftUI
import UIKit

/// Reusable circular avatar. 1:1 port of Android
/// `qaudion-android-new/core/core-ui/.../components/AvatarImage.kt`.
///
/// Four rendering modes (in priority order):
///   0. `shortNumber` non-nil → shown verbatim inside the gradient circle
///      (e.g. "103" for a PBX extension).  Has absolute priority so
///      the real short identity always beats any display-name derivation.
/// Three rendering modes (in priority order) when shortNumber is nil:
///   1. `imageURL` non-nil + load succeeds → remote image.
///   2. otherwise → solid gradient circle with up-to-2-letter initials.
///   3. group conversation → 3 stacked person silhouettes (system icon).
///
/// Sizes are configurable in the [20, 240] pt range. The upper bound
/// covers call-screen usage (160-200pt hero avatars in
/// `OutgoingCallScreen` / `IncomingCallScreen`); anything bigger should
/// be a proper profile-screen header, not this component.
///
/// Color: deterministic per-name gradient picked from
/// `presenceGradient(for:)` — same string always maps to the same colors,
/// so the same peer keeps a stable visual identity across sessions even
/// if they change display name.
struct QAudionAvatar: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    /// E2EE avatar transport (2026-07-30) — `imageURL` for a peer/self
    /// avatar is now a LOCAL `file://` path to a decrypted image
    /// (`AvatarAnnounceReceiver`'s cache, or the self-avatar cache — see
    /// `docs/E2EE_AVATAR_TRANSPORT_DESIGN.md`), never a server URL. Load
    /// state for that case lives here rather than going through
    /// `AsyncImage` (which is built around network fetches with its own
    /// URLCache — using it for a local file works but adds pointless
    /// indirection and gives us no control over decode-off-main-thread
    /// timing for a component rendered in fast-scrolling lists).
    @State private var localImage: UIImage?

    enum Kind {
        case person
        case group
    }

    let displayName: String
    let imageURL: URL?
    let kind: Kind
    let size: CGFloat
    let presenceDot: PresenceDot?
    /// Priorità assoluta rispetto a `initials(displayName)`. Pass "103"
    /// per forzare il numero interno PBX nel cerchietto. 1:1 port del
    /// parametro `shortNumber` di Android `AvatarImage.kt`.
    let shortNumber: String?

    init(displayName: String,
         imageURL: URL? = nil,
         kind: Kind = .person,
         size: CGFloat = 44,
         presenceDot: PresenceDot? = nil,
         shortNumber: String? = nil) {
        self.displayName = displayName
        self.imageURL = imageURL
        self.kind = kind
        self.size = min(240, max(20, size))
        self.presenceDot = presenceDot
        self.shortNumber = shortNumber
    }

    var body: some View {
        ZStack {
            avatarBody
            if let dot = presenceDot {
                dotOverlay(dot)
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Body

    @ViewBuilder
    private var avatarBody: some View {
        if let url = imageURL, url.isFileURL {
            localFileAvatar(url)
        } else if let url = imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    placeholderCircle
                case .success(let img):
                    img.resizable()
                       .scaledToFill()
                       .frame(width: size, height: size)
                       .clipShape(Circle())
                case .failure:
                    placeholderCircle
                @unknown default:
                    placeholderCircle
                }
            }
        } else {
            placeholderCircle
        }
    }

    /// Loads a locally-cached decrypted avatar off the main thread.
    /// `.task(id:)` re-runs whenever `url` changes (e.g. a fresher
    /// `avatar_announce` version landed and `ContactsStore
    /// .setAvatarLocalPath` bumped the URL's path) and is automatically
    /// cancelled if the view disappears mid-load (fast-scrolling lists).
    @ViewBuilder
    private func localFileAvatar(_ url: URL) -> some View {
        Group {
            if let img = localImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                placeholderCircle
            }
        }
        .task(id: url) {
            localImage = nil
            let resolvedURL = QAudionAvatar.resolveIfStale(url)
            let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let data = try? Data(contentsOf: resolvedURL) else { return nil }
                return UIImage(data: data)
            }.value
            if !Task.isCancelled {
                localImage = loaded
            }
        }
    }

    /// W-AVATARSTALEPATH (2026-08-03): `avatarUrl` is persisted (`ContactsStore`
    /// / `AvatarAnnounceCoordinator.peerAvatarFileURL`, same for the self
    /// avatar in `AvatarUploader`) as an ABSOLUTE `file://` path rooted in
    /// the app's sandbox container. That container's UUID is NOT stable
    /// across every TestFlight update/reinstall — when it rotates, every
    /// previously-cached avatar's stored path points at a directory that no
    /// longer exists. `Data(contentsOf:)` then fails SILENTLY (caught,
    /// discarded by the caller, falls back to the initials placeholder)
    /// with no error anywhere, so `ContactsStore`'s row still claims a
    /// cached version while the image is permanently gone. Confirmed live
    /// 2026-08-03: `AvatarAnnounceCoordinator`'s own bookkeeping reported a
    /// peer already cached (`recv applied=0 code=1 ... cached=2`) — i.e.
    /// "already up to date" — while nothing rendered on screen.
    ///
    /// Self-heal: the file's LAST PATH COMPONENT (`<senderId-or-hash>.jpg`
    /// / `self.jpg`) is stable — only the container prefix rotates, and
    /// every avatar in this codebase lives under the same
    /// `applicationSupportDirectory/qaudion/avatars/` convention (see
    /// `AvatarUploader.selfAvatarCacheURL` and
    /// `AvatarAnnounceCoordinator.peerAvatarFileURL`). If the stored
    /// absolute path doesn't resolve, re-root that same filename under the
    /// CURRENT container and use that instead — recovers immediately
    /// without waiting for a fresh `avatar_announce`, which the per-peer
    /// cooldown may not send again for up to an hour. Falls back to the
    /// original URL (same behaviour as before this fix — a clean "no
    /// image" placeholder) if the file genuinely isn't cached anywhere.
    private static func resolveIfStale(_ url: URL) -> URL {
        guard url.isFileURL, !FileManager.default.fileExists(atPath: url.path) else { return url }
        guard let currentDir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return url }
        let recomputed = currentDir
            .appendingPathComponent("qaudion/avatars", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
        return FileManager.default.fileExists(atPath: recomputed.path) ? recomputed : url
    }

    @ViewBuilder
    private var placeholderCircle: some View {
        Circle()
            .fill(presenceGradient(for: displayName))
            .frame(width: size, height: size)
            .overlay {
                if kind == .group {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                } else {
                    // shortNumber ha priorità assoluta (1:1 con Android AvatarImage.kt)
                    let label = shortNumber.map { $0.isEmpty ? initials(displayName) : $0 }
                        ?? initials(displayName)
                    // Riduci font del 30% per 3+ caratteri (es. "103") — stesso
                    // moltiplicatore 0.7 di Android `AvatarImage.kt` L55.
                    let fontMultiplier: CGFloat = label.count > 2 ? 0.7 : 1.0
                    Text(label)
                        .font(.system(size: size * 0.40 * fontMultiplier,
                                      weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
    }

    // MARK: - Presence dot

    private func dotOverlay(_ dot: PresenceDot) -> some View {
        let dotSize: CGFloat = max(8, size * 0.22)
        return Circle()
            .fill(dotColor(dot))
            .frame(width: dotSize, height: dotSize)
            .overlay(Circle().stroke(scheme.background, lineWidth: 1.5))
            .position(x: size - dotSize / 2 - 1,
                      y: size - dotSize / 2 - 1)
    }

    private func dotColor(_ dot: PresenceDot) -> Color {
        switch dot {
        case .online:  return Color(hex: 0x3DD598)
        case .away:    return Color(hex: 0xF2B73A)
        case .offline: return Color(hex: 0x8892A6)
        }
    }

    // MARK: - Initials

    /// Port di `initialsFor(name)` da Android `AvatarImage.kt`.
    ///
    /// Regole (in ordine):
    ///   1. Zero token → "?"
    ///   2. Un singolo token che inizia con "#" → rimuovi "#" e prendi le
    ///      prime 3 cifre (es. "#103" → "103").
    ///   3. Un singolo token composto solo da cifre → restituiscilo (fino a 3).
    ///   4. Un singolo token alfanumerico → iniziale maiuscola.
    ///   5. Più token → cerca il primo token che inizia con "#" (extension)
    ///      oppure il primo composto solo da cifre (es. "103" in "Interno 103");
    ///      se trovato restituisce quello (max 3 char, senza "#").
    ///   6. Nessun token numerico → prima iniziale + ultima iniziale maiuscole.
    ///
    /// Questo risolve il bug "Interno 103" → "I1" (vecchio) → "103" (nuovo).
    private func initials(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "?" }
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "?" }

        if tokens.count == 1 {
            let tok = tokens[0]
            if tok.hasPrefix("#") {
                return String(tok.dropFirst().prefix(3))
            }
            if tok.allSatisfy({ $0.isNumber }) {
                return String(tok.prefix(3))
            }
            return String(tok.prefix(1)).uppercased()
        }

        // Cerca prima un token "#NNN", poi un token tutto-cifre.
        if let hashTok = tokens.first(where: { $0.hasPrefix("#") }) {
            return String(hashTok.dropFirst().prefix(3))
        }
        if let numTok = tokens.first(where: { $0.allSatisfy({ $0.isNumber }) }) {
            return String(numTok.prefix(3))
        }

        // Nessun token numerico → prima+ultima iniziale.
        let first = String(tokens.first!.prefix(1))
        let last  = String(tokens.last!.prefix(1))
        return (first + last).uppercased()
    }

    // MARK: - Stable per-name gradient

    /// Deterministic gradient picker: hash the name into 6 brand-friendly
    /// palettes. Same name → same gradient across launches/devices, so a
    /// peer's avatar identity is visually stable.
    private func presenceGradient(for name: String) -> LinearGradient {
        let palettes: [(Color, Color)] = [
            (Color(hex: 0x3E7BFF), Color(hex: 0x6A3DDB)), // brand blue → violet
            (Color(hex: 0x6EE7C5), Color(hex: 0x3DD598)), // jade
            (Color(hex: 0xB388FF), Color(hex: 0xEB4D5D)), // purple → coral
            (Color(hex: 0xF2B73A), Color(hex: 0xEB4D5D)), // amber → coral
            (Color(hex: 0x00DAF3), Color(hex: 0x3E7BFF)), // cyan → blue
            (Color(hex: 0x52E3A5), Color(hex: 0x00A381))  // mint
        ]
        // Use Swift's stable string hash via SDBM-style fold (the
        // built-in `hashValue` is randomized per launch since Swift 5,
        // which would defeat the point of a "stable identity" mapping).
        var h: UInt32 = 5381
        for byte in name.utf8 {
            h = (h &* 33) &+ UInt32(byte)
        }
        let idx = Int(h % UInt32(palettes.count))
        let pair = palettes[idx]
        return LinearGradient(colors: [pair.0, pair.1],
                              startPoint: .topLeading,
                              endPoint: .bottomTrailing)
    }
}

// MARK: - PresenceDot

/// Optional online / away / offline dot anchored to the bottom-right of
/// the avatar. Matches Android's `presenceDot` parameter.
enum PresenceDot {
    case online
    case away
    case offline
}

// MARK: - Preview

#Preview {
    HStack(spacing: 16) {
        QAudionAvatar(displayName: "Mario Rossi",
                      presenceDot: .online)
        QAudionAvatar(displayName: "Anna Bianchi",
                      size: 56,
                      presenceDot: .away)
        QAudionAvatar(displayName: "Famiglia",
                      kind: .group,
                      size: 44)
        QAudionAvatar(displayName: "",
                      size: 32,
                      presenceDot: .offline)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .qAudionTheme(dark: true)
}
