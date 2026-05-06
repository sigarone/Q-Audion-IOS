import Foundation

/// Dev-only network-condition simulator (parità con Android
/// `feature-call/.../devtools/NetworkConditionSimulator.kt`).
///
/// Sits between the call-controller frame path and the wire. Permette
/// di iniettare **latency**, **packet loss**, e **offline** sui
/// frame audio per riprodurre scenarios di field-failure su Wi-Fi
/// pulito.
///
/// Scope: pure-dev, OFF by default. Una sola instance globale
/// (process-singleton) — cambia profilo via `setProfile(_)`.
///
/// Integrazione iOS:
///   - `CallService.startCall` capture.onFrame:
///       Task {
///         if NetworkConditionSimulator.shared.shouldDropOutbound() { return }
///         await NetworkConditionSimulator.shared.delayOutbound()
///         // ... existing encrypt + send
///       }
///   - `CallService.handleIncomingEncryptedFrame`:
///       if NetworkConditionSimulator.shared.shouldDropInbound() { return }
///       // ... existing decrypt + playback
///
/// L'overhead in modalità Off è **zero**: `isPassthrough()` è una
/// singola volatile read; le tre `should*` returning false su
/// `Profile.off` quindi i call sites sono branch-predicted off-path.
public final class NetworkConditionSimulator: @unchecked Sendable {

    public struct Profile: Equatable, Sendable {
        public let id: String
        public let label: String
        public let outboundDelayMs: Int
        public let outboundLossRatio: Double
        public let inboundLossRatio: Double
        public let offline: Bool

        public init(id: String, label: String,
                    outboundDelayMs: Int = 0,
                    outboundLossRatio: Double = 0,
                    inboundLossRatio: Double = 0,
                    offline: Bool = false) {
            self.id = id; self.label = label
            self.outboundDelayMs = outboundDelayMs
            self.outboundLossRatio = outboundLossRatio
            self.inboundLossRatio = inboundLossRatio
            self.offline = offline
        }
    }

    /// 6 preset profiles — same labels and values as Android source of
    /// truth (`NetworkConditionSimulator.Profile.*` data objects).
    public static let off = Profile(id: "off", label: "Normale (rete reale)")

    public static let highLatency = Profile(
        id: "highLatency",
        label: "Alta latenza (300 ms)",
        outboundDelayMs: 300
    )

    public static let lossy = Profile(
        id: "lossy",
        label: "Perdita pacchetti 5%",
        outboundLossRatio: 0.05,
        inboundLossRatio: 0.05
    )

    public static let veryLossy = Profile(
        id: "veryLossy",
        label: "Perdita pacchetti 20%",
        outboundLossRatio: 0.20,
        inboundLossRatio: 0.20
    )

    public static let satellite = Profile(
        id: "satellite",
        label: "Satellite (700 ms + 2%)",
        outboundDelayMs: 700,
        outboundLossRatio: 0.02,
        inboundLossRatio: 0.02
    )

    public static let offline = Profile(
        id: "offline",
        label: "Offline (tutti i pacchetti scartati)",
        outboundLossRatio: 1.0,
        inboundLossRatio: 1.0,
        offline: true
    )

    // Le 6 preset sono `static let` sulla classe wrapper, NON case di
    // un enum. Devono essere referenziate con il qualifier completo
    // `NetworkConditionSimulator.X`, perché lo shorthand `.X` cerca
    // i member su `Profile` (struct interna) e non sull'outer class.
    // In particolare `.offline` farebbe match con `Profile.offline:Bool`.
    public static let availableProfiles: [Profile] = [
        NetworkConditionSimulator.off,
        NetworkConditionSimulator.highLatency,
        NetworkConditionSimulator.lossy,
        NetworkConditionSimulator.veryLossy,
        NetworkConditionSimulator.satellite,
        NetworkConditionSimulator.offline
    ]

    /// Process-wide singleton. Lo expose-iamo come static let così
    /// CallService può fare `NetworkConditionSimulator.shared.shouldDropOutbound()`
    /// senza bisogno di DI explicit.
    public static let shared = NetworkConditionSimulator()

    private let lock = NSLock()
    private var _active: Profile = NetworkConditionSimulator.off

    public var active: Profile {
        lock.lock(); defer { lock.unlock() }
        return _active
    }

    /// Set the active profile. Effetto immediato sul prossimo frame —
    /// no call restart needed, lo state machine del CallController
    /// non ha state proprio sul simulator.
    public func setProfile(_ p: Profile) {
        lock.lock()
        _active = p
        lock.unlock()
    }

    /// Fast-path check: se true, il call frame path ignora completamente
    /// il simulator (case `.off`). Branch-predicted off-path quando
    /// l'app è in produzione e nessuno ha attivato il sim.
    public func isPassthrough() -> Bool {
        return active.id == "off"
    }

    /// Returns true se questo frame outbound DEVE essere droppato.
    /// Determinismo: se `offline == true`, sempre true; altrimenti
    /// random check contro `outboundLossRatio`.
    public func shouldDropOutbound() -> Bool {
        let p = active
        if p.offline { return true }
        if p.outboundLossRatio <= 0.0 { return false }
        return Double.random(in: 0..<1) < p.outboundLossRatio
    }

    /// Stesso semantics ma per inbound. La probabilità è IID
    /// rispetto a outbound (real network drops on each leg are
    /// indipendent).
    public func shouldDropInbound() -> Bool {
        let p = active
        if p.offline { return true }
        if p.inboundLossRatio <= 0.0 { return false }
        return Double.random(in: 0..<1) < p.inboundLossRatio
    }

    /// Async delay equivalent to Android's `delayOutbound()`. Chiamato
    /// PRIMA di `transport.send` sul TX path: ritarda il frame della
    /// `outboundDelayMs` configurata. Il peer naturalmente stretches
    /// il jitter buffer per accomodare.
    public func delayOutbound() async {
        let d = active.outboundDelayMs
        if d > 0 {
            try? await Task.sleep(nanoseconds: UInt64(d) * 1_000_000)
        }
    }
}
