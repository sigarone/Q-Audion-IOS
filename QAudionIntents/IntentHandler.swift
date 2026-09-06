import Intents

/// SiriKit Intents Extension handler for "Hey Siri, chiama X su Q-Audion"
/// (CarPlay/Siri state-of-the-art plan, S1 —
/// docs/superpowers/plans/2026-09-06-carplay-state-of-the-art.md).
///
/// Deliberately a thin pass-through: per Apple's own `INStartCallIntent`
/// documentation, an Intents extension must never place the call itself —
/// it only confirms the request is plausible and hands off to the main app,
/// which does the actual Q-Audion contact resolution (`SiriCallResolution`,
/// QAudionEngine) and dials through the exact same `AppState.startCall`
/// path CarPlay and the in-app dial screen already use. Kept free of any
/// `QAudionEngine`/Contacts dependency on purpose — an Intents extension
/// runs under a tight, separate memory budget from the host app, the same
/// reason `QAudionBroadcastExtension` avoids linking the full engine
/// product (see that target's own `project.yml` comment).
final class IntentHandler: INExtension, INStartCallIntentHandling {

    override func handler(for intent: INIntent) -> Any {
        return self
    }

    // MARK: - Resolve

    func resolveCallCapability(
        for intent: INStartCallIntent,
        with completion: @escaping (INCallCapabilityResolutionResult) -> Void
    ) {
        let capability = intent.callCapability == .unknown ? .audioCall : intent.callCapability
        completion(.success(with: capability))
    }

    func resolveContacts(
        for intent: INStartCallIntent,
        with completion: @escaping ([INPersonResolutionResult]) -> Void
    ) {
        guard let contacts = intent.contacts, !contacts.isEmpty else {
            completion([INPersonResolutionResult.needsValue()])
            return
        }
        // Pass-through resolution only — whether this person is actually a
        // reachable Q-Audion contact is decided in-app, after handoff (see
        // AppState.handleSiriStartCall + SiriCallResolution). Rejecting here
        // would need this extension to read Q-Audion's own contact store,
        // which it deliberately does not link.
        completion(contacts.map { .success(with: $0) })
    }

    func resolveDestinationType(
        for intent: INStartCallIntent,
        with completion: @escaping (INCallDestinationTypeResolutionResult) -> Void
    ) {
        // Q-Audion is VoIP-only — every call is a "normal" destination, never
        // emergency/voicemail/redial in the PSTN sense those other cases model.
        completion(.success(with: .normal))
    }

    func resolveCallRecordToCallBack(
        for intent: INStartCallIntent,
        with completion: @escaping (INCallRecordResolutionResult) -> Void
    ) {
        // "Call back the last missed call" redialing is not implemented yet
        // (tracked as a known gap in the S1 plan, not silently dropped).
        completion(.notRequired())
    }

    // MARK: - Confirm / handle

    func confirm(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        guard let contacts = intent.contacts, !contacts.isEmpty else {
            completion(INStartCallIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil))
            return
        }
        completion(INStartCallIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        // SiriKit builds the NSUserActivity (carrying an INInteraction with
        // this intent + response) itself and hands it to the main app via
        // scene(_:continue:) / .onContinueUserActivity — this extension never
        // constructs that activity or touches CallKit directly.
        completion(INStartCallIntentResponse(code: .continueInApp, userActivity: nil))
    }
}
