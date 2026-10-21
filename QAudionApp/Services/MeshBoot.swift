import Foundation
import QAudionEngine

/// What has to happen for the mesh before any UI exists: the log sink (so the mesh lines go out under the tag "mesh"),
/// the identity, and the radio. The app delegate's launch calls it (a Bluetooth relaunch by the system has no
/// scene, so `AppState.initialize()` is not reached); it also wires the inbound handlers to `AppState.shared` and again, harmlessly, from `AppState.initialize()`.
@MainActor
enum MeshBoot {

    /// Sends the engine's mesh lines to the runtime log under the tag "mesh" (WARN lines as warnings).
    static func installLogSink() {
        MeshLog.install(sink: { level, tag, message in
            if level == .warn {
                RTLog.warn(tag, message)
            } else {
                RTLog.info(tag, message)
            }
        })
    }

    /// Reads the identity key (never creates one), derives the node id and, if the consent and the antenna choice
    /// allow it, brings the radio up so the system can hand back the connections it kept. A locked Keychain leaves the
    /// radio off; the foreground retry in `AppState` tries again.
    static func bootIdentityAndRadio() {
        installLogSink()
        // The receive path first: a packet that arrives the moment the radio is up must find its handler.
        AppState.shared.wireMeshInbound()
        let identity = SovereignIdentityManager()
        if let signingPublic = identity.loadIdentity()?.signingPublic, signingPublic.count == 32 {
            MeshRuntime.shared.configureLocalIdentity(identityKeyRaw: signingPublic)
            MeshRuntime.shared.autoStartIfEnabled()
        } else {
            MeshRuntime.shared.configureLocalIdentity(identityKeyRaw: nil, source: "locked")
        }
    }
}
