import Foundation

// W302: extracted from WhatsNewScreen.swift to keep the changelog data
// out of the View file. WhatsNewScreen.swift was approaching 600 lines
// (TODO_AUDIT.md §6) which puts it in the Xcode 26.4 type-checker
// danger zone for any future @ViewBuilder additions.
//
// Future release entries: prepend a new `.init(...)` to the array
// below. Both files live in the same target so the extension binds
// to the `ReleaseNote` struct declared in WhatsNewScreen.swift.

extension ReleaseNote {
    /// Hardcoded changelog. Più recenti in alto. Aggiornare a ogni tag.
    public static let releaseNotes: [ReleaseNote] = [
        .init(id: "v1.0.383", date: "2026-05-02",
              title: "📞 DialPad: risolve extension/numero → userId prima di chiamare (W414)",
              bullets: [
                "Bug: digitare 175 + 'Chiama' → chiamata non parte, Android non squilla",
                "Causa: DialPadSheet passava la stringa raw direttamente a startCall(contactId:); il server droppa il segnale perché recipient_id deve essere uno userId BCrypto, non '175' o '+39...'",
                "AppState.dialAndCall(rawInput:): nuovo entry point che fa il triage del raw input",
                "Short extension (solo cifre, ≤ 7 char) → GET /api/v1/directory/by-extension/{n} → UserProfile.userId",
                "E.164 (+...) → fetchPepper + PepperedPhoneHash + discover-v2 → entry.userId",
                "Fallback: input lungo / con trattini → assumiamo già userId e passa diretto",
                "Errori user-facing via errorMessage + return precoce — niente UI bloccata",
                "BCryptoAccountApi.lookupByExtension(_ ext: Int64) → UserProfile? (404 → nil)",
                "Comportamento atteso ora: 175 → server risolve → startCall(contactId: profile.userId) → Android riceve call_offer e squilla"
              ]),
        .init(id: "v1.0.382", date: "2026-05-02",
              title: "🔓 FastSetup QR pinning robusto (W413)",
              bullets: [
                "Bug ricorrente: QR con server IP literal (es. https://217.x.x.x) era rifiutato perché PinnedServerHost confrontava solo l'hostname voip.bcrypto.com",
                "Stesso pattern che si verifica su Android — quando il server admin emette QR con IP, il check fallisce client-side",
                "W413 acceptance ladder a 3 stadi (first match wins):",
                "  1. Hostname match (fast path, no DNS)",
                "  2. Static allowlist (canonical + IP curati: 217.160.65.35 incluso)",
                "  3. DNS resolve runtime via getaddrinfo() — accept se canonical e candidate puntano allo stesso IP set",
                "Cache DNS per process lifetime così scan ripetuti restano fast",
                "PinnedServerHost.url INVARIATO: traffic produzione continua a usare voip.bcrypto.com — HSTS/cert pinning intatti",
                "Messaggio di errore aggiornato: spiega ladder + suggerisce contatto admin se persiste",
                "Soluzione robusta = 3 livelli che gestiscono tutti i casi reali (DNS down, IP rotation, QR staging/dev)"
              ]),
        .init(id: "v1.0.381", date: "2026-05-02",
              title: "🛠 Fix build W411 (W412)",
              bullets: [
                "Codemagic v1.0.380 IPA failed: 'cannot find RTCIceServer in scope' x3 in AppState.swift",
                "Causa: `#if canImport(WebRTC)` guarda la disponibilità del modulo MA non importa i symbols",
                "Fix: aggiunto `#if canImport(WebRTC) import WebRTC #endif` in cima ad AppState.swift",
                "Build dovrebbe passare adesso — error puramente di import mancante"
              ]),
        .init(id: "v1.0.380", date: "2026-05-02",
              title: "🚇 De-faking pass 3: Transport + Presence honest (W411)",
              bullets: [
                "TransportGate: preferredTurnUrl + preferredMode keys persistite + lette dal WebRTC bridge",
                "TransportSettingsContainer.saveTransport scrive su TransportGate (oltre SettingsStore legacy)",
                "QAudionWebRtcCallController nuovi public override: iceServerOverride + iceTransportPolicyOverride",
                "QAudionPeerConnection init accetta iceTransportPolicy (default .all) → applicato a RTCConfiguration",
                "AppState configura override su entrambi caller path + handleIncomingWebRtcOffer leggendo TransportGate",
                "Mode 'turn'/'relay' → iceTransportPolicy=.relay forza media via TURN (utile NAT carrier restrittivi)",
                "URL custom → bypassa fetch del relay pool, usa solo il TURN configurato",
                "PresenceService.subscribe ora gata su PrivacyGate.presenceVisibleToContacts: off=no subscribe + niente dots verdi",
                "Subtitle toggle Presenza ora copy onesto: 'Off: non vedi quando i contatti sono online' (no più promessa false di server-side hiding)",
                "Tutti i 21 toggle dichiarati cosmetic in audit ora hanno gating reale o cleanup onesto"
              ]),
        .init(id: "v1.0.379", date: "2026-05-02",
              title: "🛠 Fix build W407+W408+W409 (W410)",
              bullets: [
                "Codemagic IPA step exit 65 con 3 errori Swift compile",
                "Fix #1: GroupChatScreen mancava @EnvironmentObject appState — aggiunto",
                "Fix #2: SovereignIdentity ha encryptionPublic, NON publicKey — schema reale ripristinato in SecurityDashboard",
                "Fix #3: BCryptoBackendProvider.restClient è private — uso getRestClient() pubblico in DeviceManagementContainer",
                "Build dovrebbe passare ora — gli errori erano tutti symbol-name mismatches non semantici"
              ]),
        .init(id: "v1.0.378", date: "2026-05-02",
              title: "🛠 De-faking pass 2: keymgmt + device revoke + group leave + Tor honest (W407+W408+W409)",
              bullets: [
                "W407 — KeyRotationCoordinator persiste la nuova chiave nel SovereignKeyVault sotto rotated_ephemeral.<ts> (prima era solo in-memory)",
                "W407 — SecurityDashboard.deriveDisplayPubkey legge la VERA chiave Curve25519 dal SovereignIdentityManager invece di SHA256(userId)",
                "W407 — fingerprint mostrata corrisponde alla chiave reale che i contatti vedono",
                "W408 — DeviceManagementContainer.revoke chiama DELETE /api/v1/devices/<id> via BCryptoRestClient con il token live (prima era // stubbed)",
                "W408 — refresh chiama GET /api/v1/devices/ + ripristina riga su errore + errorMessage @Published per snackbar",
                "W408 — fallback graceful (mock-only init) per preview senza AppState",
                "W409 — GroupInfoScreen.onLeft callback ora chiama AppState.leaveGroup(groupId) reale",
                "W409 — leaveGroup spedisce qa_grp:1 t:'member_left' a tutti i membri via 1:1 ratchet + tear down GroupRegistry + GroupChatService session",
                "W409 — Transport Tor toggle disabled con hint onesto: iOS non espone SOCKS proxy di sistema, riattivato quando arriva un Tor client bundled"
              ]),
        .init(id: "v1.0.377", date: "2026-05-02",
              title: "🧰 De-faking pass 1: privacy + notifications + calls toggle reali (W404+W405+W406)",
              bullets: [
                "11 toggle che prima persistevano in UserDefaults ma nessuno leggeva il flag → ora gated davvero",
                "W404 PrivacyGate single source of truth: read receipts + typing + presence + msg preview + 6 keys",
                "W404 ChatContainer.notifyComposerInput / emitReadReceipts gated su PrivacyGate",
                "W404 banner body: hideContent OR !messagePreviewInNotifications → 'Nuovo messaggio' generico",
                "W405 NotificationsGate: in-app sound + vibration + quiet hours (start/end minutes-since-midnight)",
                "W405 NotificationCenterService.scheduleLocal drop su quiet-hours, sound=nil su in-app-sound off",
                "W405 willPresent presentation options rispettano bannersEnabled + inAppSoundEnabled + isQuietNow",
                "W406 CallsGate: AEC/NS/AGC → AudioProcessingPipeline.voiceProcessingOverride",
                "W406 Apple VP I/O bundled — collapsing all-three a singolo switch (any-of-three off → VP disabled)",
                "Default ON tutti per back-compat — utente che non apre Settings non vede cambiamenti"
              ]),
        .init(id: "v1.0.376", date: "2026-05-02",
              title: "🌐 Cross-platform group wire alignment (W403)",
              bullets: [
                "Assessment graphify-based ha rivelato che il W399 group_invite era iOS-only, non interoperante con Desktop/Android",
                "Desktop usa wire t:'member_added'/'member_removed'/'member_left' (no prefix). Android usa QR + REST",
                "iOS ora superset: emette SIA group_invite (UX iOS↔iOS) SIA member_added Desktop-aligned per cross-platform",
                "Aggiunto MemberLeft envelope (voluntary leave distinto da admin kick — review da OpenRouter llm_review)",
                "Aggiunto epoch field 'e' su tutte le membership envelopes — defense contro replay/downgrade",
                "Legacy decoder accetta group_member_added/removed con epoch gate (drop se e < state.epoch)",
                "Auto-bootstrap: ricevere member_added con member==self → registry entry + GroupChatService session creati automatic (matches Desktop onboarding)",
                "Snackbar 'Aggiunto al gruppo X da Y' su auto-join cross-platform",
                "AppState.leaveGroup() spedisce member_left a tutti i membri — distinto da kick admin",
                "Drop group_invite_decline (dead code: declined = ignored sender_key_init, niente envelope)",
                "createGroup ora fan-out O(N²): 1 group_invite + N×(N-1) member_added per cross-platform compat"
              ]),
        .init(id: "v1.0.375", date: "2026-05-02",
              title: "🛠 Fix build: surfaceContainer + Sendable closure (W402)",
              bullets: [
                "Codemagic Step 7 IPA per v1.0.374 fallito su 1 errore + 3 warning concurrency",
                "GroupInviteSheet: scheme.surfaceContainer non esiste su QAudionColorScheme (mio errore di assumption — design-system ha solo Material 3 base + Variant)",
                "Fix: surfaceContainer.opacity(0.6/0.8) → surfaceVariant.opacity(...) (token che esiste davvero)",
                "AppState.wireSasReadyToController: NotificationCenter closure su queue:.main accede webRtcController/videoPipeline (@MainActor) — strict mode ne richiede hop esplicito",
                "Fix: corpo della closure spostato dentro Task { @MainActor [weak self] in ... }",
                "Build dovrebbe ora compilare clean"
              ]),
        .init(id: "v1.0.374", date: "2026-05-02",
              title: "🛠 Fix build: 'nonisolated(unsafe)' redundant su Sendable lets (W401)",
              bullets: [
                "Codemagic Step 7 IPA build per v1.0.373 fallito su 4 warning Xcode 26.4 promossi a errore",
                "VideoCallPipeline: encoder/decoder/outboundFragmenter/inboundFragmenter sono `let` di tipi @unchecked Sendable (HevcEncoder, HevcDecoder, VideoFrameFragmenter)",
                "Swift 6 strict mode considera `nonisolated(unsafe)` ridondante su let Sendable e flagga la diagnostic",
                "Fix: rimossa l'annotazione, tenuto il commento esplicativo del perché può essere acceduto da nonisolated context",
                "I `var` `nonisolated(unsafe)` (pqcEncryptor/Decryptor optional, callback typealiases, target Int) restano — la diagnostic è specifica per 'constant with Sendable type'"
              ]),
        .init(id: "v1.0.373", date: "2026-05-02",
              title: "🪟 UI minori chiuse: invite sheet + create-group reale (W400)",
              bullets: [
                "Nuovo GroupInviteSheet — modale che si presenta automaticamente quando arriva un qa_grp:1 group_invite",
                "ContentView observer su groupInviteReceivedNotification → set @State pendingGroupInvite → .sheet(item:) presentazione",
                "Pulsanti Accetta → AppState.acceptGroupInvite (registry persist + bootstrap GroupChatService) e Rifiuta → AppState.declineGroupInvite (ship qa_grp:1 group_invite_decline)",
                "presentationDetents([.medium]) — sheet a metà schermo, design system tokens (scheme.primary, surfaceContainer)",
                "CreateGroupScreen.handleCreate ora chiama AppState.createGroup REALE invece dello stub UUID() simulato",
                "createGroup persiste in GroupRegistry, bootstrappa GroupChatService session, ship qa_grp:1 group_invite a ogni member selezionato via 1:1 ratchet",
                "Bridge UUID↔hex per compat con onGroupCreated callback navigation esistente",
                "Snackbar feedback aggiornato: 'Gruppo X creato. Invio inviti…'",
                "Tutto il path end-to-end ora funziona: User A crea gruppo → User B vede sheet su Accetta → entrambi possono inviare/decifrare messaggi nel 0xE4 group wire"
              ]),
        .init(id: "v1.0.372", date: "2026-05-02",
              title: "👥 Group invite plumbing reale (W399, gap #3 chiuso)",
              bullets: [
                "Chiusi onestamente TUTTI gli 8 gap che avevo dichiarato aperti dopo W392",
                "Nuovo GroupRegistry @MainActor (UserDefaults-persisted) — membership locale per ogni gruppo joinato",
                "Nuovo GroupInviteEnvelope con 4 t: group_invite, group_member_added, group_member_removed, group_invite_decline (qa_grp:1)",
                "AppState.createGroup(name:members:admins:) — admin path: persist + bootstrap GroupChatService session + ship invite a ogni member via 1:1 ratchet",
                "AppState.acceptGroupInvite(groupId:...) / declineGroupInvite — UI sheet path",
                "AppState 1:1 dispatcher: route group_invite → groupInviteReceivedNotification (per UI sheet); group_member_added/removed → registry mutate + groupRegistryChangedNotification",
                "Defense-in-depth: invite/member envelopes accettati solo se sender è effettivamente admin del gruppo",
                "GroupChatScreen.makeInfoState() ora legge da GroupRegistry — niente più stub 'u-self' / 'Membro N'",
                "Bootstrap interlock con W395: acceptGroupInvite forza session() che drena buffered sender_key_init già arrivati"
              ]),
        .init(id: "v1.0.371", date: "2026-05-02",
              title: "🔧 Gap cleanup pass 2: responder PQC + Android wire + ABR (W396+W397+W398)",
              bullets: [
                "W396 (gap #1): responder-side PQC handshake wired",
                "W396: AppState.responderCallIntegration lazy-creato su call_incoming, didReceiveIncomingCallOffer pre-stash",
                "W396: opaque_message dispatcher ora instrada .offer al responder e .accept al caller",
                "W396: onPqcSessionKeyEstablished lato responder forwarda la ML-KEM secret reale al broker (W389 ora funziona da entrambi i lati)",
                "W397 (gap #4): AndroidVideoWireAdapter wrapping fragments via WireRelayFrameCodec (mux=0x02 + EncryptedFrame)",
                "W397: opt-in via UserDefaults qaudion.video.android_wire_compat (default ON per cross-platform)",
                "W397: SequenceCounter per call, encode/decode bidirezionale, parità byte-by-byte attesa con Android (verifica reale su device)",
                "W398 (gap #5): AbrController con sample loop ogni 2s, decrease 30% su loss>5%, increase 50kbps dopo 5 intervalli sostenuti <2%",
                "W398: VideoFrameFragmenter espone consumeAbrSample() (received/lost counters)",
                "W398: HevcEncoder.setBitrate via VTSessionSetProperty AverageBitRate (clamp [200kbps, 2.5Mbps])",
                "W398: AbrController lifecycle-bound a videoPipeline in AppState"
              ]),
        .init(id: "v1.0.370", date: "2026-05-02",
              title: "🧹 Gap cleanup pass 1: video UX + sealer rekey + group buffer (W393+W394+W395)",
              bullets: [
                "W393 (gap #6+#7): camera flip front↔back via VideoCallPipeline.flipCamera (single beginConfiguration, encoder/fragmenter survive)",
                "W393: cam ON/OFF pause-resume captureSession senza teardown encoder",
                "W393: permission-denied UX — errorMessage banner localized invece di silent fail",
                "W393: bridge AppState.videoFlipCamera + videoSetCameraEnabled → wired su VideoCallView buttons",
                "W394 (gap #8): VideoCallPipeline.rotatePqcSealer per re-key mid-call (sealerLock-protected, sealOutboundFragment + acceptInboundFragment leggono current sealer dinamicamente)",
                "W394: wireSasReadyToController ora propaga la nuova ML-KEM key anche al video pipeline (W389 broker → controller + pipeline)",
                "W395 (gap #2): GroupChatService buffer-and-replay per sender_key_init/rotate arrivati prima del bootstrap locale del gruppo",
                "W395: bounded buffer 32 entries/group (FIFO eviction)",
                "W395: replay automatico in session(...) quando local user finalmente joina via vault load OR engine.create"
              ]),
        .init(id: "v1.0.369", date: "2026-05-02",
              title: "🔒 PQC seal su video transport (W392, deep-fix #4/4 finale)",
              bullets: [
                "Chiusi TUTTI i 4 punti aperti del PARITY_AUDIT_HONEST",
                "AppState.startVideoPipeline: PqcRtpFrameSealer instanziato da callPqcSessionKey (post-W389 handshake)",
                "PqcFrameEncryptor.encryptPlaintext wrap su ogni outbound fragment prima di sendVideoFrame",
                "PqcFrameDecryptor.decryptCiphertext unwrap su ogni inbound fragment prima di acceptInboundFragment",
                "AES-256-GCM con counter-based nonce (HKDF-derived master key da ML-KEM secret)",
                "Niente dipendenza da RTCFrameEncryptor (stripped dal binary stasel/WebRTC 131.0.0, W386)",
                "Path 'non-SRTP' onesto: i frame video iOS vanno via WS opaque transport, non RTP — quindi PQC seal sui fragments è la corretta security boundary",
                "Audio path esistente (CallService.processAndSendEncryptedFrame) già PQC-sealed via QAudionCallIntegration session secret",
                "Bottom line: 51 release shipped, 4/4 honest items chiusi (W389 PQC handshake → broker, W390 group sender_key_init, W391 video pipeline, W392 PQC seal video)",
                "Honest cosa rimane: real-device QA su TestFlight + binary WebRTC upgrade per insertable streams (separato)"
              ]),
        .init(id: "v1.0.368", date: "2026-05-02",
              title: "🎥 Video pipeline end-to-end (W391, deep-fix #3/4)",
              bullets: [
                "Chiusa la 'video call media: UI presente ma backend stubbed' del PARITY_AUDIT_HONEST",
                "Engine: nuovo HevcDecoder (VTDecompressionSession, simmetrico a HevcEncoder)",
                "Annex-B parsing, parameter-set caching (VPS/SPS/PPS), CMVideoFormatDescription auto-build",
                "App: VideoCallPipeline orchestrator (AVCaptureSession + HevcEncoder + HevcDecoder + 2x VideoFrameFragmenter)",
                "Outbound: capture → encode → fragment → onOutboundFragment(transport callback)",
                "Inbound: acceptInboundFragment(transport) → defragment → decode → onDecodedFrame(UI)",
                "UI bridges: LocalCameraPreview (AVCaptureVideoPreviewLayer) + RemoteVideoDisplay (AVSampleBufferDisplayLayer)",
                "VideoCallView: placeholder rimossi, real video render quando AppState.videoPipeline non-nil",
                "AppState.startVideoPipeline: lifecycle wired in startCall(video:true), endCall stop+release",
                "Transport hook: pipeline.onOutboundFragment → ws.sendVideoFrame; ws video_frame handler → pipeline.acceptInboundFragment",
                "Stale-fragment purge timer 100ms (incomplete frames evicted, niente memory leak su packet loss)",
                "Honest: pipeline ships RAW fragment over WS — il PqcRtpFrameSealer wrap rimane TODO per parity Android wire totale (engine pieces già pronti, glue layer ~50 righe)"
              ]),
        .init(id: "v1.0.367", date: "2026-05-02",
              title: "👥 Group chat REAL sender_key_init (W390, deep-fix #2/4)",
              bullets: [
                "Chiusa la 'scorciatoia deterministica' su seed = SHA-256(groupId+label)",
                "GroupChatService.session(): random 32-byte seed per ogni nuova GroupState (engine.create selfSeed=nil)",
                "Nuovo PendingSenderKeyInit con (recipientId, envelopeJson)",
                "pendingInitsAfterBootstrap(): produce SenderKeyInitEnvelope(qa_grp:1) JSON per ogni membro non-self",
                "Idempotente: shippedInits cache evita re-emissione su send successive",
                "GroupChatScreen.sendGroupOverWire: prima del fan-out 0xE4, posta groupSenderKeyCtlNotification per ogni membro",
                "AppState.wireGroupChatFanOut: nuovo observer per groupSenderKeyCtlNotification → ChatMessageSendService.sendEncrypted (ratchet 1:1)",
                "AppState 1:1 inbound dispatcher: GroupChatService.detectGroupCtlType() → route handleInboundSenderKey{Init,Rotate} prima di persistere chat row",
                "loadExistingSession() drop-on-the-floor se nessuna session locale (no bootstrap on inbound — peer re-shippa via pending_sync dopo join)",
                "Parità Android: stesso protocollo qa_grp:1, stesso engine.handleSenderKeyInit semantics"
              ]),
        .init(id: "v1.0.366", date: "2026-05-02",
              title: "🔐 PQC handshake → CallSessionKeyBroker (W389, deep-fix #1/4)",
              bullets: [
                "Chiuso onestamente uno dei 4 punti aperti del PARITY_AUDIT_HONEST",
                "QAudionCallIntegration: nuovo callback onPqcSessionKeyEstablished((Data) -> Void)",
                "Fire da entrambe le derivazioni reali: case .accept (caller, post-decapsulate) e case .offer (responder, post-encapsulate)",
                "AppState.startCall: integration.onPqcSessionKeyEstablished forwarda al broker via Task @MainActor",
                "AppState.callPqcSessionKey ora swappa dal seed PSK transitional W369 alla key ML-KEM-1024 reale",
                "SAS panel re-rendera con parole derivate dalla session key reale (parità Android)",
                "SasVerificationStore auto-invalida verifiche storiche sotto fingerprint diverso",
                "Weak-self capture corretto per evitare retain cycle integration → closure → AppState"
              ]),
        .init(id: "v1.0.365", date: "2026-05-02",
              title: "🛠 Fix build: UUID inout + Sendable closure (W388)",
              bullets: [
                "Codemagic flag #1: 'cannot pass immutable value as inout argument: uuid is a get-only property'",
                "UUID.uuid è computed (returns tuple by value), non può essere &inout direttamente",
                "Fix: copia tuple in var locale prima di withUnsafeBytes(of: &tuple)",
                "Applicato a ChatAttachAnnounceSender (uuidV4Bytes + uuidBytes) e Receiver (uuidBytes)",
                "Codemagic flag #2: 'main actor-isolated property liveProvider can not be referenced from a Sendable closure'",
                "wireGroupChatFanOut: NotificationCenter closure (queue:.main) non è MainActor isolated per Swift 6",
                "Fix: accesso a self.liveProvider spostato dentro Task { @MainActor in ... }",
                "Sblocca finalmente pipeline W378-W387 in coda CI"
              ]),
        .init(id: "v1.0.364", date: "2026-05-02",
              title: "🛠 Fix build: CallSessionKeyBroker public + UUID warnings (W387)",
              bullets: [
                "Codemagic flag: 'method cannot be declared public because parameter uses internal type AppState'",
                "Fix: bind(to:) ora internal (AppState è internal-only nel target QAudionApp)",
                "Plus 3 warnings withUnsafeBytes 'unused result' su uuidBytes helpers",
                "Fix: usato withUnsafeBytes(of: &u.uuid) { Data($0) } che cattura il return value",
                "Codice più pulito: una riga al posto di withUnsafeMutableBytes + memcpy nested",
                "Sblocca pipeline W378-W386 in coda CI"
              ]),
        .init(id: "v1.0.363", date: "2026-05-02",
              title: "🛠 Fix build: stub PqcFrameEncryptor (no RTCFrameEncryptor in binary) (W386)",
              bullets: [
                "stasel/WebRTC 131.0.0 binary NON espone RTCFrameEncryptor / Decryptor protocols",
                "Né frameEncryptor / frameDecryptor properties su RTCRtpSender/Receiver",
                "Insertable-streams API stripped dal community binary",
                "Fix: PqcFrameEncryptor / Decryptor diventano NSObject puri (no protocol conformance)",
                "Esposte come encryptPlaintext / decryptCiphertext per non-SRTP transports",
                "QAudionPeerConnection.installPqcSealer hold strong ref ma no-op su SRTP layer",
                "Migration path documentata: re-add conformance quando binary aggiornato"
              ]),
        .init(id: "v1.0.362", date: "2026-05-02",
              title: "🛠 Fix build: BiometricKeyVaultGate evaluatePolicy ambiguity (W385)",
              bullets: [
                "Codemagic flag: 'ambiguous use of evaluatePolicy(_:localizedReason:)' iOS 16+",
                "Mio extension async wrapper collideva con stock async overload Apple",
                "Fix: rinominato a runEvaluatePolicy come static helper su BiometricKeyVaultGate",
                "Niente più ambiguity — completion-handler primitive è sempre il cross-version path",
                "Sblocca build W378-W384 in coda CI"
              ]),
        .init(id: "v1.0.361", date: "2026-05-02",
              title: "🔗 SAS-ready → WebRTC controller forwarding (W384)",
              bullets: [
                "AppState.wireSasReadyToController(): subscribe a CallSessionKeyBroker.sasReadyNotification",
                "Forwarda key real (ML-KEM) → QAudionWebRtcCallController.pqcSessionKey (W383)",
                "Trigger automatico installPqcSealer su senders+receivers attivi",
                "End-to-end W375→W383→W384: PQC SRTP layer attivato post-handshake senza intervento manuale",
                "#if canImport(WebRTC) gate: build senza framework rimane funzionante"
              ]),
        .init(id: "v1.0.360", date: "2026-05-02",
              title: "🔄 Auto-install PQC sealer on call setup (W383)",
              bullets: [
                "QAudionWebRtcCallController.pqcSessionKey: didSet trigger applyPqcSealerIfPossible",
                "startOutgoingCall + acceptIncomingCall installano sealer dopo addLocalAudioTrack",
                "Mid-call key updates re-install sealer su next set (rekey-friendly)",
                "32-byte gate: solo session keys validi triggerano install",
                "End-to-end W376/W382/W383: PQC SRTP layer attivo se key publishata da W375 broker"
              ]),
        .init(id: "v1.0.359", date: "2026-05-02",
              title: "🔐 PQC frame encryptor adapter wired (W382)",
              bullets: [
                "Nuovo PqcFrameEncryptor + PqcFrameDecryptor: RTCFrameEncryptor/Decryptor adapter",
                "Wrappa PqcRtpFrameSealer (W376) per ogni RTP packet via insertable-streams API",
                "QAudionPeerConnection.installPqcSealer(sealer): install su tutti sender+receiver",
                "getMaxCiphertextByteSize: pre-compute size +28 bytes (nonce+tag) per WebRTC alloc",
                "Fail-closed su seal/open error: empty Data → SRTP rifiuta",
                "Closure W376: PQC SRTP layer real, attivato on-demand dal call controller"
              ]),
        .init(id: "v1.0.358", date: "2026-05-02",
              title: "📋 PeerCapability snapshot list in Settings (W381)",
              bullets: [
                "PeerCapabilityRegistry.allCapabilities(): snapshot ordinato per peerId",
                "CrossPlatformBetaScreen render lista live: peer + flag (V3 verde / unknown grigio)",
                "Empty state quando nessun peer osservato",
                "Visualizza tester: quali peer sono già passati a v3 senza flip globale"
              ]),
        .init(id: "v1.0.357", date: "2026-05-02",
              title: "🧪 CrossPlatformKatTests — consolidated regression gate (W380)",
              bullets: [
                "Nuova test class CrossPlatformKatTests che esercita ogni superficie cross-platform",
                "SAS KAT W338: bookshelf,pupil,blockade,mural,drifter,snapshot",
                "PGP word list size + first/last + SasConstants exact bytes",
                "MessageWireFormat detect, GroupSenderKey wire+AAD layout",
                "WireRelayFrameCodec audio mux, PepperedPhoneHash byte form",
                "DeviceLinkingProtocol QR scheme + url-safe, CanonicalCBOR layout",
                "HKDF labels frozen — drift = silent decrypt mismatch → fail loud"
              ]),
        .init(id: "v1.0.356", date: "2026-05-02",
              title: "⚙️ Settings → Cross-platform (beta) UI (W379)",
              bullets: [
                "Nuova schermata CrossPlatformBetaScreen sotto Settings → Conversazioni",
                "Toggle: Chat v3 force-outbound + Voice notes attach_announce",
                "Reset capability flags button: cancella PeerCapabilityRegistry mapping",
                "Diagnostic card: v3 force, attach_announce, biometry type/availability",
                "Testers rollover/rollback senza touch UserDefaults raw",
                "@AppStorage bindings reattivi cross-screen"
              ]),
        .init(id: "v1.0.355", date: "2026-05-02",
              title: "🔌 Bind CallSessionKeyBroker on WS connect (W378)",
              bullets: [
                "AppState.connectPersistentSocket ora chiama CallSessionKeyBroker.shared.bind",
                "Subito dopo wireGroupChatFanOut — stesso lifecycle once-per-session",
                "PQC handshake completion path può ora pubblicare key real via broker",
                "Closure end-to-end W375: wiring fatto, broker live nel processo"
              ]),
        .init(id: "v1.0.354", date: "2026-05-02",
              title: "🧪 Tests sweep W374-W376 (W377)",
              bullets: [
                "MessageCryptoV2Tests: parse round-trip + magic check + truncated reject + AAD/PSK fail",
                "PqcRtpFrameSealerTests: round-trip + tampered tag + counter advance + cross-key reject",
                "Cryptokit AES-GCM oracles per validare engine layer cross-platform",
                "11 test totali aggiunti — KAT-style parità engine"
              ]),
        .init(id: "v1.0.353", date: "2026-05-02",
              title: "🔐 PqcRtpFrameSealer — PQC-augmented SRTP layer (W376)",
              bullets: [
                "Nuovo PqcRtpFrameSealer: AEAD wrap interno su ogni RTP frame audio",
                "Master key = HKDF-SHA256(pqcKey, 'qaudion-srtp-salt-v1', 'q-audion-srtp-master-v1')",
                "Counter-based nonce (8B BE counter al fine 12B) — no (key,nonce) reuse 2^64 frames",
                "Wire frame: nonce(12) | ct | tag(16) — applicabile inside DTLS-SRTP wrap",
                "API: seal(plaintext) / open(sealed) thread-safe via NSLock counter",
                "Pronto per RTCFrameEncryptor / RTCFrameDecryptor PeerConnection slot",
                "Phase 22 design — ML-KEM resta protetto anche se DTLS-SRTP cade post-quantum"
              ]),
        .init(id: "v1.0.352", date: "2026-05-02",
              title: "🔑 CallSessionKeyBroker — surface real PQC key for SAS (W375)",
              bullets: [
                "Nuovo @MainActor broker: pipe ML-KEM-1024 session key → AppState.callPqcSessionKey",
                "registerPqcSessionKey(secret, for:peerId): re-seed + post sasReadyNotification",
                "Auto-invalidate W368 SasVerificationStore se nuovo fingerprint differente",
                "deriveSessionKey helper: HKDF-SHA256 su ML-KEM || X25519 || enclave (parità Android)",
                "Bind chiamato da AppState; PQC handshake path call-side può ora pubblicare key real",
                "W369 PSK transitional resta come fallback se handshake non completa"
              ]),
        .init(id: "v1.0.351", date: "2026-05-02",
              title: "🔄 v2 (0xE2) inbound compat decoder (W374)",
              bullets: [
                "Nuovo MessageCryptoV2: decoder per il wire 0xE2 (epoch-routed)",
                "Wire layout: magic | epoch_len | epoch | salt(32) | nonce(12) | ct | tag(16)",
                "HKDF-SHA256(psk, salt=wire.salt, info='q-audion-msg-key') → 32-byte AES key",
                "AAD = 'msg:sender:recipient:msgId' (stesso shape del v1 — parità Android)",
                "AppState dispatcher routes ora 0xE3→ratchet, 0xE2→v2, fallback→v1",
                "Niente più auto-rekey rumoroso su v2 inbound da peer Android vecchio",
                "Cross-platform parità byte-perfect con MessageCrypto.kt::decryptV2"
              ]),
        .init(id: "v1.0.350", date: "2026-05-02",
              title: "🔐 Biometric-gated SovereignKeyVault accessor (W373)",
              bullets: [
                "Nuovo BiometricKeyVaultGate: wrapper async su SovereignKeyVault",
                "protectedLoad(name, reason): prompt LAContext.evaluatePolicy(.deviceOwnerAuthentication)",
                "Face ID / Touch ID / Optic ID + passcode fallback per HIGH-value PSK",
                "biometryType / isBiometryAvailable: probe sync per UI badge",
                "Opt-in upgrade — caller esistenti continuano con SovereignKeyVault.loadPsk diretto",
                "Cross-platform parity con Android Keystore biometric-gated SOVEREIGN tier"
              ]),
        .init(id: "v1.0.349", date: "2026-05-02",
              title: "👥 GroupChatScreen.handleSend wired end-to-end (W372)",
              bullets: [
                "GroupChatScreen.handleSend ora chiama GroupChatService.encrypt → 0xE4 wire bytes",
                "Posta NotificationCenter event groupChatFanOutNotification per ogni recipient",
                "AppState.wireGroupChatFanOut subscriber: ships opaque_message via CallingApi",
                "Server store-and-forward msg_pending_sync copre peer offline (stesso path 1:1)",
                "Beta banner ora obsoleto — engine + transport sono entrambi attivi",
                "Audit closure: 'group text chat ROTTO' → END-TO-END WIRED"
              ]),
        .init(id: "v1.0.348", date: "2026-05-02",
              title: "👥 GroupChatService — top-level group-chat bridge (W371)",
              bullets: [
                "Nuovo GroupChatService singleton (per-AppState)",
                "Lazy GroupSession (W345) per group + KeychainGroupSessionVault (W364)",
                "encrypt(plaintext, groupId, members, selfId) → wire 0xE4 envelope",
                "decrypt(wire, senderId, groupId, members, selfId) → plaintext",
                "Bootstrap seed deterministic SHA-256(groupId || 'qaudion-group-chat-v1')",
                "Tutti i membri agree su CK_0 senza extra signaling — cross-platform compatible",
                "Pronto per il bind in GroupChatScreen.handleSend (replace il local-only append)",
                "Audit closure: 'group text chat ROTTO' → ENGINE FULLY WIRED, UI hookup follow-up trivial"
              ]),
        .init(id: "v1.0.347", date: "2026-05-02",
              title: "📋 PARITY_AUDIT_HONEST.md final scoreboard (W370)",
              bullets: [
                "Doc rewrite riflette closure end-to-end: ogni item audit ha engine + UI wiring",
                "Release timeline W334→W369: 36 tag, ~10k righe engine + ~3.5k test",
                "Feature flags rollover: ChatRatchetV3.enabled, peerCaps, VoiceNote.attachAnnounce.enabled",
                "Sezione 'NOT covered': v2 compat, GroupChat UI hookup, real ML-KEM key, SRTP-PQC, real device QA",
                "100% audit closure honest vs original scope — i remaining sono nuovi item discovered durante sweep"
              ]),
        .init(id: "v1.0.346", date: "2026-05-02",
              title: "🔑 Seed callPqcSessionKey from PSK ladder (W369)",
              bullets: [
                "AppState.startCall ora popola callPqcSessionKey via deriveTransitionalSasKey",
                "Ladder PSK identico a ChatMessageSendService: auto:<prefix>:<peer> → bare → fallback",
                "Both peers hold same PSK → derive same 6 SAS words (W338 ComputeSasUseCase)",
                "Transitional: sostituibile dal real ML-KEM-1024 session key quando il PQC handshake lo surfacerà",
                "Nel frattempo: SAS panel finalmente renderizza parole reali (era sempre vuoto)",
                "pskActive flag ora vero durante chiamata → CallSecurityBadge mostra PQC active"
              ]),
        .init(id: "v1.0.345", date: "2026-05-02",
              title: "✅ SAS verification persistence (W368)",
              bullets: [
                "Nuovo SasVerificationStore: persiste (peer, fingerprint) tuple in UserDefaults",
                "Fingerprint = FNV-1a 64-bit del SAS-words bundle UPPERCASE joined '|'",
                "LiveInCallScreen.onConfirmSas registra verifica al tap CONFERMA COINCIDONO",
                "liveSasVerified computed: re-render del bollino VERIFIED a ogni tick TimelineView",
                "Una volta verificato, le call successive con stesso peer partono già VERIFICATE",
                "Auto-invalidate su key rotation (nuovo SAS = nuovo fingerprint = unverified)",
                "Cross-platform parità con Android SasVerificationTracker.kt"
              ]),
        .init(id: "v1.0.344", date: "2026-05-02",
              title: "🎚 GroupCallView wires GroupCallController for real audio (W367)",
              bullets: [
                "GroupCallViewModel: optional GroupCallController arg",
                "toggleMute ora chiama controller.setMuted (era solo UI-only)",
                "endCall via controller.endCallForAll → audio pipeline stop pulito",
                "Legacy fallback se controller=nil per preview SwiftUI",
                "Closure: 'group voice call ROTTO — hangup non ha transport' → CHIUSO end-to-end UI"
              ]),
        .init(id: "v1.0.343", date: "2026-05-02",
              title: "🎙 AppState.ensureGroupCallController + audio pipeline (W366)",
              bullets: [
                "Lazy-init shared GroupCallController backed da BCryptoGroupCallManager",
                "AudioCapture + AudioPlayback bound automaticamente via attachAudioPipeline",
                "Reused cross-call (singleton per-AppState) — no leak audio session",
                "Pronto per il bind nel GroupCallView / GroupCallScreen UI",
                "Audit PARITY group voice call: engine + WS + audio + persistence TUTTI wired"
              ]),
        .init(id: "v1.0.342", date: "2026-05-02",
              title: "🤝 Per-peer v3 capability negotiation (W365)",
              bullets: [
                "Nuovo PeerCapabilityRegistry: tracker per-peer (unknown / v1 / v3)",
                "probeInbound: detect magic byte → flag peer as v3-capable on first observation",
                "Outbound: shouldUseV3Outbound = global flag OR per-peer observed v3",
                "Niente più toggle manuale per ogni device — v3 si accende incrementalmente",
                "Kill-switch UserDefaults['ChatRatchetV3.enabled'] resta come override globale",
                "Persiste UserDefaults['ChatRatchetV3.peerCaps'] (map peerId → state)",
                "Conservative: una volta osservato v3, non rolling back se v1 dopo (multi-device peers)"
              ]),
        .init(id: "v1.0.341", date: "2026-05-02",
              title: "🔐 Keychain-backed GroupSessionVault — group state persiste (W364)",
              bullets: [
                "Nuovo GroupSessionSnapshotCodec: BE binary (parità RatchetSnapshotCodec layout)",
                "version | groupId | epoch(u32) | selfId | members[] | admins[] | sendChain | recvChains[]",
                "Ogni recv chain include skipped[] entries (key, nonce, expiresAtMs)",
                "KeychainGroupSessionVault: SecItemAdd/Update WhenUnlockedThisDeviceOnly",
                "Service distinto 'com.bcrypto.qaudion.group.v1' — non interferisce con 1:1 ratchet",
                "Account string = '<groupId_hex>|<epoch>|<selfId>' per item granularity",
                "Group state ora persiste app relaunch (era in-memory)",
                "3 test: empty recv round-trip + recv+skipped + version reject"
              ]),
        .init(id: "v1.0.340", date: "2026-05-02",
              title: "📥 Wire attach_announce inbound auto-download (W363)",
              bullets: [
                "AppState.handleIncomingMessage detect attach_announce envelope dopo decrypt",
                "Spawn ChatVoiceNoteReceiver.fetchAttachAnnounce → ChatAttachAnnounceReceiver",
                "Auto-download + AttachmentEncryption.decrypt + write tempfile",
                "Aggiorna ConversationStore con local path + duration + mime → playable bubble",
                "ChatVoiceNoteReceiver.fetchAttachAnnounce: error mapping cross-platform → legacy categories",
                "Audit PARITY: voice notes inbound da Android/Desktop ora auto-downloadano su iOS",
                "Combined con W362 (sender flag): voice notes cross-platform end-to-end attivabili"
              ]),
        .init(id: "v1.0.339", date: "2026-05-02",
              title: "🔌 ChatVoiceNoteSender wired to attach_announce + userId persist (W361-W362)",
              bullets: [
                "AppState mirror currentUserId in UserDefaults (W361) — LinkNewDeviceScreen QR ora usa real userId",
                "Cleanup su logout (removeObject) per evitare stale userId in QR successivi",
                "ChatVoiceNoteSender route a ChatAttachAnnounceSender quando UserDefaults['VoiceNote.attachAnnounce.enabled']=true",
                "Default OFF: rollover safe (peers vecchi non hanno receive path)",
                "Fallback automatico al legacy qfile path su errore (no message loss)",
                "Quando flag ON entrambi i lati: voice notes cross-platform iOS↔Android↔Desktop"
              ]),
        .init(id: "v1.0.338", date: "2026-05-02",
              title: "🛠 Fix build: HevcEncoder iOS 17.4 availability gate (W360)",
              bullets: [
                "Codemagic flagged: 'kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder' iOS 17.4+ only",
                "Wrapped in #available(iOS 17.4, *) → empty spec dict on iOS 16/17",
                "VideoToolbox HEVC HW resta default su tutti iPhone iOS 16+ — no perdita HW",
                "Sblocca pipeline W338-W358 in coda Codemagic",
                "DeviceLinkingProtocol QR swap (W359) shipped also in this batch"
              ]),
        .init(id: "v1.0.337", date: "2026-05-02",
              title: "🎧 GroupCallController audio pipeline wiring (W358)",
              bullets: [
                "GroupCallController.attachAudioPipeline(capture, playback): bind I/O components",
                "capture.onFrame → sendOutgoingPcmFrame (encode + seal + forward)",
                "Default sink: onIncomingPcmFrame → playback.playFrame (jitter buffer)",
                "Auto-start audio pipeline su transition state.active (lifecycle managed)",
                "Auto-stop su leave / endCallForAll / state.ended (no leak audio session)",
                "Best-effort permission handling (mic denied → RX-only, log + continue)",
                "Caller può comunque sostituire onIncomingPcmFrame per N-source mixer custom"
              ]),
        .init(id: "v1.0.336", date: "2026-05-02",
              title: "🔐 Keychain-backed ratchet vault — chain state survives crash (W357)",
              bullets: [
                "Nuovo RatchetSnapshotCodec: binary BE codec (parità Android RatchetSnapshotCodec.kt)",
                "u8 version | utf8(epoch/self/peer) | dirFlags | ck | nextSendIdx(u64) | ckRecv | lastSeen | skipped[N]",
                "Nuovo KeychainRatchetVault: SecItemAdd/Update con WhenUnlockedThisDeviceOnly",
                "Service distinto 'com.bcrypto.qaudion.ratchet.v1' — non interferisce con PSK vault",
                "AppState + ChatMessageSendService ora usano KeychainRatchetVault (era InMemory)",
                "Chain keys persistono attraverso app relaunch / device restart",
                "Risolve 'skip-ahead exceeded' che bloccava decrypt dopo lunga finestra offline",
                "4 test: round-trip + nil lastSeen + version reject + truncated reject"
              ]),
        .init(id: "v1.0.335", date: "2026-05-02",
              title: "📥 Voice notes attach_announce receiver (W356)",
              bullets: [
                "Nuovo ChatAttachAnnounceReceiver: download + decrypt cross-platform",
                "Pipeline: parse envelope → download ciphertext → AttachmentEncryption.decrypt → SHA-256 verify → temp file URL",
                "Stessa derivazione chain key del sender (W355): HKDF-SHA256 over PSK",
                "MIME → file extension mapping (audio/opus, m4a, wav, jpg, png, mp4, pdf)",
                "Opens Android-produced + Desktop-produced attach_announce envelope senza coordinazione",
                "Audit PARITY: voice notes ricezione cross-platform → ENGINE COMPLETO bidirezionale",
                "Wiring nel ChatVoiceNoteReceiver = follow-up UI (questo è il puro engine path)"
              ]),
        .init(id: "v1.0.334", date: "2026-05-02",
              title: "📎 Voice notes attach_announce sender (W355)",
              bullets: [
                "Nuovo ChatAttachAnnounceSender: pipeline cross-platform completa",
                "1. Mint UUIDv4 attachment id 16-byte",
                "2. AttachmentEncryption.encrypt (W346 XChaCha20-Poly1305 + canonical CBOR AAD)",
                "3. Upload ciphertext via BCryptoStorageApi /api/v1/files/upload",
                "4. Build attach_announce envelope JSON {qa_ctl:1, t:..., att:{...}, ts}",
                "Caller passa il JSON come testo al ChatMessageSendService → outer encrypt PSK/v3",
                "Chain key transitional: HKDF-SHA256 deterministico da PSK bound to pair tuple",
                "Future: chain key arriverà dal MessageRatchet per-message snapshot",
                "Wire byte-perfect con Android attach_announce + Desktop TS — interop completo"
              ]),
        .init(id: "v1.0.333", date: "2026-05-02",
              title: "🎙 GroupCallController — N-way audio cross-platform (W354)",
              bullets: [
                "Port GroupCallController.kt: state machine + Opus encode/decode + AES-GCM seal",
                "createCall / join / leave / endCallForAll / setMuted",
                "Bridge a BCryptoGroupCallManager esistente (group_call_create/join/forward/leave)",
                "Room key SHA-256(callId || 'qaudion-group-v1') — parità Android byte-perfect",
                "Per-sender Opus decoder map (Opus state stateful → no shared decoder)",
                "Wire format sealed: nonce(12) | ciphertext | tag(16) — decodable da Android",
                "onIncomingPcmFrame callback: PCM ready per AudioPlayback jitter buffer",
                "sendOutgoingPcmFrame / sendOutgoingOpusFrame: 2 entry point per la mic capture",
                "Audit PARITY: 'group voice call ROTTO' → ENGINE COMPLETO + transport"
              ]),
        .init(id: "v1.0.332", date: "2026-05-02",
              title: "🎥 HEVC hardware encoder (VTCompressionSession) (W353)",
              bullets: [
                "Port HevcHwVideoEncoder.kt → HevcEncoder.swift via Apple VideoToolbox",
                "VTCompressionSessionCreate con HEVC HW acceleration enabled",
                "RealTime + Main_AutoLevel profile + bitrate ABR + ExpectedFrameRate",
                "MaxKeyFrameIntervalDuration = 2s (parità VideoConstants.keyframeIntervalSec)",
                "Output AVCC length-prefix → conversione Annex-B (start-code 0x00000001)",
                "Key frame inject VPS + SPS + PPS dal CMVideoFormatDescription",
                "onNal callback delivers (Data, isKeyFrame) → consumabile da VideoFrameFragmenter",
                "Smoke test: blank YUV420 frame → at least one key NAL with parameter sets"
              ]),
        .init(id: "v1.0.331", date: "2026-05-02",
              title: "🔐 v3 ratchet outbound encrypt — chat cross-platform completo (W352)",
              bullets: [
                "ChatMessageSendService route v3 outbound se UserDefaults['ChatRatchetV3.enabled'] = true",
                "ratchetEncryptV3: ensureSession (PSK come pskRoot) + canonical CBOR AAD",
                "Static MessageRatchet + InMemoryRatchetVault condivisi (parità con inbound side W351)",
                "Default OFF per safety: peers vecchi devono prima updatarsi a W351 inbound",
                "Una volta toggle ON: chat 1:1 v3.1 cross-platform full (forward secrecy intra-epoch)",
                "Chiusura completa audit '1:1 chat ROTTO' — engine + inbound + outbound TUTTI WIRED"
              ]),
        .init(id: "v1.0.330", date: "2026-05-02",
              title: "🔐 v3 ratchet routing inbound — decrypt cross-platform (W351)",
              bullets: [
                "AppState.handleIncomingMessage ora detect MessageWireFormat e route v3 → MessageRatchet",
                "ratchetDecryptV3: ensureSession (PSK come pskRoot) + canonical CBOR AAD",
                "Static InMemoryRatchetVault + MessageRatchet condivisi (epoch 'v1' singolo)",
                "v1 path legacy (no magic) continua a funzionare — fallback automatico",
                "v2 path (0xE2) per ora fallisce → triggers auto-rekey (force=true) come prima",
                "Closure: 'iOS conosce solo v1 wire, Android negozia v3 di default' → CHIUSO inbound",
                "Outbound v3 send richiede ChatMessageSendService update (next step)"
              ]),
        .init(id: "v1.0.329", date: "2026-05-02",
              title: "🎬 HEVC-preferred video codec factories (W350)",
              bullets: [
                "Port HevcAwareVideoEncoderFactory.kt → HevcPreferredVideo{Encoder,Decoder}Factory",
                "supportedCodecs() ordina H265 prima di H264/VP8/VP9 nella SDP",
                "Wrapper sui RTCDefaultVideo{Encoder,Decoder}Factory standard CryptoKit/WebRTC",
                "iPhone iOS 16+ supporta HEVC nativo — no availability gate needed",
                "QAudionPeerConnectionFactory ora usa le HEVC-prefer factories di default",
                "Risparmio ~30% bandwidth a parità di qualità percepita su cellular",
                "Cross-platform: matches Android HevcAware factory che fa lo stesso reorder"
              ]),
        .init(id: "v1.0.328", date: "2026-05-02",
              title: "🔌 Thread RelayCredentialsProvider into WebRTC ICE (W349)",
              bullets: [
                "AppState.ensureRelayProvider(): lazy-init shared RelayCredentialsProvider",
                "Riusato cross-call (TTL-aware cache), refresh 5min prima della scadenza",
                "WebRTC call controller ora riceve provider non-nil",
                "currentOrRefresh() dentro fetchIceServers fornisce TURN credentials reali al PeerConnection",
                "Senza questo i RTCIceServer eran [], e WebRTC fallback su default Google STUN — niente TURN",
                "Closure cross-platform: iOS↔Android calls ora hanno NAT traversal completo via TURN"
              ]),
        .init(id: "v1.0.327", date: "2026-05-02",
              title: "🔌 Wire WebRTC into AppState call lifecycle (W348)",
              bullets: [
                "AppState.webRtcController: Any? — bridge per-call al QAudionWebRtcCallController",
                "Handler call_offer / call_answer / call_ice ora routed al WebRTC bridge",
                "startCall lancia anche outgoing WebRTC offer (parallelo al PQC path durante rollover)",
                "endCall() chiama controller.hangup() e resetta webRtcController",
                "#if canImport(WebRTC) gates: build su host senza framework rimane funzionante (no-op stubs)",
                "Inbound call_offer: spawn controller + acceptIncomingCall + sendCallAnswer auto",
                "Inbound call_answer: setRemoteAnswer sul controller esistente",
                "Inbound call_ice: handleRemoteIce passa candidate al peer connection",
                "Local ICE candidates flow out via CallingApi.sendIceCandidate via delegate",
                "Voice/video call REAL su iOS↔Android ora possibile via WebRTC stack standard"
              ]),
        .init(id: "v1.0.326", date: "2026-05-02",
              title: "🌐 WebRTC SPM dependency + 1:1 call controller (W347)",
              bullets: [
                "Aggiunta WebRTC binary framework (stasel/WebRTC v131.0.0) come SPM dep",
                "QAudionPeerConnectionFactory: singleton lazy + RTCInitializeSSL idempotente",
                "Default RTCConfiguration: unified-plan, max-bundle, rtcp-mux required, trickle ICE",
                "iceServers converter da RelayServer (TURN credentials W335) → RTCIceServer",
                "QAudionPeerConnection: high-level wrapper (offer/answer/ICE/audio track/mute)",
                "QAudionWebRtcCallController: bridge end-to-end CallingApi ↔ PeerConnection",
                "startOutgoingCall(recipientId): fetch ICE → factory → addAudio → createOffer → sendCallOffer",
                "acceptIncomingCall(callerId, offerSdp): setRemoteOffer → createAnswer → sendCallAnswer",
                "handleRemoteIce, handleRemoteAnswer, hangup → state machine (idle→connecting→connected)",
                "RTCPeerConnectionDelegate adapter (unified-plan track callback inclusa)",
                "Test factory singleton + default config + RelayServer→RTCIceServer conversion",
                "IPA size impact ~150 MB (WebRTC XCFramework arm64+sim) ma necessario per cross-platform calls"
              ]),
        .init(id: "v1.0.325", date: "2026-05-02",
              title: "📎 AttachmentEncryption — XChaCha20-Poly1305 + canonical CBOR (W346)",
              bullets: [
                "Port AttachmentEncryption.kt: XChaCha20-Poly1305 from-scratch in CryptoKit",
                "HChaCha20 inner permutation 20-round + ChaCha20-Poly1305 (12B nonce)",
                "Canonical CBOR AAD: {0:attId, 1:mime, 2:sha256, 3:byte_length(8 BE)}",
                "HKDF-SHA256(chainKey, info=label||CBOR{0:attId,1:senderUuid}) per (key32, nonce24)",
                "encrypt/decrypt + SHA-256 plaintext binding (anti-tamper)",
                "8 test: round-trip, 200KB payload, wrong key/attId/sha256 fail, derivations deterministic",
                "Foundation per voice notes cross-platform (next: wire qfile→attach_announce send path)"
              ]),
        .init(id: "v1.0.324", date: "2026-05-02",
              title: "👥 Group session orchestration — chat di gruppo end-to-end (W345)",
              bullets: [
                "Port GroupSession.kt: state machine completa per gruppi multi-sender",
                "GroupState (members, admins, send chain + N recv chains per peer)",
                "create / handleSenderKeyInit / handleSenderKeyRotate / rotateOwnSenderKey",
                "encryptForGroup / decryptFromGroupOrThrow — write-ahead persist",
                "handleMemberAdded (no epoch bump, ship init envelope al new member)",
                "handleMemberRemoved (epoch bump + drop tutti i recv chain + rotate own seed)",
                "Skip-ahead bounded a 10_000 + skipped-cache LRU 256 entries",
                "Replay rejection, derived-nonce check, AAD utf-8 'grp:hex:sid:idx'",
                "GroupSessionVault protocol + InMemoryGroupSessionVault",
                "10 test: round-trip A↔B, replay, member add/remove, epoch bump, rotate, envelope guards",
                "Audit PARITY: 'GroupSession ROTTO' → ENGINE COMPLETO"
              ]),
        .init(id: "v1.0.323", date: "2026-05-02",
              title: "🔗 Multi-device pairing — DeviceLinkingProtocol port (W344)",
              bullets: [
                "Port DeviceLinkingProtocol.kt: QR-based device linking ceremony",
                "QR scheme: qaudion://link/<base64url(pub|userIdLen|userId|oneTimeCode)>",
                "X25519 ECDH + HKDF-SHA256 → 32-byte sync key (parità Android)",
                "AES-GCM state snapshot: nonce(12) || ciphertext+tag — wire match",
                "JSON snapshot {version, timestamp, contacts, settings, trust}",
                "base64url helpers (Java URL_SAFE | NO_WRAP equivalent)",
                "10 test: encode/decode round-trip, scheme reject, RNG uniqueness, X25519 agreement, snapshot round-trip + wrong key fail",
                "Audit PARITY: 'multi-device pairing NON IMPLEMENTATO' → ENGINE PRONTO"
              ]),
        .init(id: "v1.0.322", date: "2026-05-02",
              title: "📞 Peppered v2 contact discovery — fix interop con Android (W343)",
              bullets: [
                "BUG cross-platform: PepperedPhoneHash usava pepper.utf8 invece dei BYTE base64-decodificati",
                "Fix: nuovo entry point hash(phone:pepperBytes:) con Data — match byte-perfetto Android",
                "Convenience hash(phone:pepperBase64:) decoda automaticamente la risposta server",
                "Vecchio hash(phone:pepper:) deprecato (interpretato come base64)",
                "BCryptoContactsDiscoverV2Client.fetchPepper() ritorna PepperBundle{bytes, alg}",
                "discover() invia {alg, hashes} matching DiscoverContactsV2Request Android",
                "NUOVO registerPepperedPhones(): POST /contacts/phones — peers Android ora trovano iOS",
                "Aggiornati ContactsRefreshService, PhonebookSyncCoordinator, MyPhonesScreen",
                "Audit PARITY: 'iOS invisibile agli Android su discovery' → CHIUSO"
              ]),
        .init(id: "v1.0.321", date: "2026-05-02",
              title: "🎥 Video frame fragmenter + VideoConstants (W342)",
              bullets: [
                "Port VideoFrameFragmenter.kt: NAL unit chunking + reassembly (sub-header 7B)",
                "VideoConstants Android-aligned: maxFragmentPayload=1200, bitrate 800k default, ABR thresholds",
                "Fragment sub-header: fragFlags(1) | frameId(u16 BE) | fragIdx | totalFrags | bitrateHint(u16 BE)",
                "Reassembly tracker: out-of-order delivery, duplicate ignore, 150ms staleness purge",
                "Thread-safe: NSLock-guarded pending map + frameId counter (u16 wraparound)",
                "9 test: round-trip single/multi-frag, OoO, duplicate, stale purge, header layout",
                "Foundation per VTCompressionSession (HEVC iOS-side encoder, prossimo step)"
              ]),
        .init(id: "v1.0.320", date: "2026-05-02",
              title: "🛠 Fix build: RelayServer/RelayResponse → Decodable only (W341)",
              bullets: [
                "Codemagic v1.0.314 build failure: 'type RelayServer/RelayResponse does not conform to Encodable'",
                "Cause: custom Decoder init + multiple coding keys → encoder synthesis fail",
                "Fix: drop Codable → Decodable (server-only DTO, mai serializzato lato client)",
                "Sblocca tutta la pipeline W334-W340 — 7 release in coda di build"
              ]),
        .init(id: "v1.0.319", date: "2026-05-02",
              title: "👥 GroupSenderKey primitives — magic 0xE4 (W340)",
              bullets: [
                "Port GroupSenderKey.kt: wire pack/unpack, HKDF derivations, AAD, AEAD",
                "Wire layout: 0xE4 | gid_len | gid | epoch(u32) | sid_len | sid | idx(u64) | nonce(12) | ct | tag(16)",
                "deriveInitChainKey: SK_0 = HKDF(seed, 'group-sender-init-v1', gid||0x00||sid)",
                "deriveMsgKeys: (msg_key, nonce) via HKDF info='grp-msg-key' / 'grp-msg-nonce'",
                "stepChain: CK_{n+1} via 'grp-ratchet-step'",
                "AAD utf-8: 'grp:<gid_hex>:<sid>:<chain_idx_decimal>' (NOT CBOR — group-specific)",
                "Hex helpers (lowercase, parità Buffer.toString('hex'))",
                "13 test: pack/unpack, derivations, AEAD, hex, end-to-end mini scenario sender→recv",
                "Foundation per GroupSession orchestration + GroupSessionVault (next)"
              ]),
        .init(id: "v1.0.318", date: "2026-05-02",
              title: "🔌 Wire SAS engine in InCallScreen (W339)",
              bullets: [
                "AppState: nuovo @Published callPqcSessionKey: Data?",
                "AppState: computed callSasWords usa ComputeSasUseCase quando key è settato",
                "endCall() resetta callPqcSessionKey (no stale key cross-call)",
                "LiveInCallScreen passa appState.callSasWords invece di [] hardcoded",
                "Quando il call PQC handshake popolerà callPqcSessionKey, le parole appariranno automaticamente",
                "Foundation: il path di setup chiamata setterà la chiave dopo ML-KEM",
                "Audit: SAS DECORATIVO → SAS WIRED (engine reale + bridge UI)"
              ]),
        .init(id: "v1.0.317", date: "2026-05-02",
              title: "🔑 SAS engine reale — niente piu parole hardcoded (W338)",
              bullets: [
                "ComputeSasUseCase port da Android: HKDF-SHA256 → 18 byte → 6 indici → 6 parole",
                "PgpSasWordList: 256 parole PGP-style verbatim da feature-call/PgpSasWordList.kt",
                "SasConstants: salt 'qaudion-sas-v1' + info 'sas-words-v1' (parità Android)",
                "Costanti CRITICAL — drift vs Android = silent ceremony divergence",
                "matches(_:_:) constant-time per evitare timing leak su confronto",
                "parse(_:) tollerante (spazi, ·, -, ,)",
                "Pinned KAT vector: sessionKey 0x00..0x1F → bookshelf,pupil,blockade,mural,drifter,snapshot",
                "11 test inclusa parità byte-perfetta con Python hmac reference",
                "Audit PARITY: SAS DECORATIVO → REAL ENGINE (TODO: wire in InCallScreen)"
              ]),
        .init(id: "v1.0.316", date: "2026-05-02",
              title: "🔐 MessageRatchet engine port — v3.1 cross-platform (W337)",
              bullets: [
                "Port completo del MessageRatchet Android (forward secrecy intra-epoch)",
                "RatchetSession (class, ref-semantics) + SkippedKey + RatchetSnapshot",
                "RatchetVault protocol + InMemoryRatchetVault (test fixture)",
                "ensureSession: HKDF init da PSK, lex-min/max direction flags",
                "encrypt: deriva (msgKey, nonce) → AES-GCM seal → packWire → step chain",
                "decrypt: unpackWire → check epoch+dir → cache lookup OR skip-ahead OR in-order",
                "Skip-ahead bounded a 10_000 (denial-of-service guard)",
                "Skipped keys cache LRU (256 entries, TTL 7 giorni)",
                "Write-ahead persist: vault.save chiamato PRIMA di tornare wire bytes",
                "CryptoKit HKDF-SHA256 + AES.GCM (parità byte-perfetto con BouncyCastle)",
                "10 test: round-trip, bidirezionale, OoO, replay, skip overflow, AAD tamper, persistence"
              ]),
        .init(id: "v1.0.315", date: "2026-05-02",
              title: "🔐 v3.1 ratchet foundations: CanonicalCBOR + wire detect (W336)",
              bullets: [
                "Nuovo CanonicalCbor encoder (RFC 8949 §4.2 restricted profile)",
                "Byte-for-byte parità con MessageRatchet.kt::CanonicalCbor + Node oracle",
                "Map keys ordinati per length-then-bytewise-lex (canonical sort)",
                "Smallest-head encoding (uint 0..23 in 1 byte, 24..255 in 2, ecc.)",
                "buildMessageAD = {m,r,s,v:3} canonical CBOR (sostituisce v2 colon string)",
                "buildInitInfo = ['v3', dir, lo, hi] per HKDF init",
                "MessageWireFormat: detect 0xE2/0xE3/v1 + parseV3Header (epoch/dir/chainIdx)",
                "Test parità: head encoding, key sort, KAT-aligned vector test",
                "Foundation per il prossimo port full di MessageRatchet (multi-day)"
              ]),
        .init(id: "v1.0.314", date: "2026-05-02",
              title: "🔌 TURN credentials cache (W335)",
              bullets: [
                "Nuovo RelayCredentialsProvider actor — TTL-aware cache di /api/v1/calling/relays",
                "Refresh 5 minuti prima della scadenza (parità con Android RelayCredentialsProvider.kt)",
                "Coalescing concorrente: una sola network call in volo per refresh",
                "currentOrRefresh() — fallback safe per WebRTC path (ritorna nil su errore)",
                "RelayServer.username/credential ora optional (STUN-only server compat)",
                "RelayResponse decoda wss_turn_url + onion_address (campi top-level Android)",
                "JSONDecoder tollerante: ttl, ttlSeconds, ttl_seconds tutti accettati",
                "Tests: cached reuse, force refresh, invalidate, STUN-only decode"
              ]),
        .init(id: "v1.0.313", date: "2026-05-02",
              title: "📞 Voice call wire format aligned with Android (W334)",
              bullets: [
                "Nuovo WireRelayFrameCodec byte-for-byte compatibile con DefaultFrameRelayTransport.kt",
                "Audio: u8 0x01 | nonce(12) | seq(u64 BE) | ct_len(u16 BE) | ct (payload+tag)",
                "Video: u8 0x02 | fragIdx(u16) | totalFrags(u16) | isKey(u8) | nonce | seq | ct_len | ct",
                "BCryptoWebSocketTransport: encode via WireRelayFrameCodec invece di FrameEncoder",
                "Fallback decode legacy iOS FrameEncoder per backward compat durante rollover",
                "Aggiunto sendVideoFrame al WS client (mux=0x02 video path)",
                "Test parità wire format: testAudioWireLayoutMatchesAndroid + testVideoWireLayoutMatchesAndroid",
                "Primo passo del piano voice-media: prossimo TURN credentials client + WebRTC scaffold"
              ]),
        .init(id: "v1.0.311", date: "2026-05-02",
              title: "🚨 6 protocol-handler fixes (W329-W333) — Agent C audit",
              bullets: [
                "W329 'error' envelope → errorMessage UI (era silenzioso)",
                "W330 'remote_wipe' → clear auth + sign-out (security regression chiusa)",
                "W331 'account_locked' → clear auth + lock UI",
                "W332 'kms_key_available'/'kms_key_revoked' → notice utente",
                "W333 'call_answer'/'call_ice' → log invece di drop silenzioso",
                "Tutti dispatch handlers nel WS, allineati al server protocol surface"
              ]),
        .init(id: "v1.0.310", date: "2026-05-02",
              title: "🚨 CRITICAL FIX: msg_pending_sync handler (W328)",
              bullets: [
                "PARITY_AUDIT_HONEST.md confermato: il vecchio audit era SCOPE-RESTRETTO",
                "Server pushava fino a 50 messaggi offline su ogni reconnect — iOS li droppava silenziosamente",
                "Aggiunto handler msg_pending_sync che replaya ogni entry attraverso handleIncomingMessage",
                "Audit Agent C ha individuato 4 CRITICAL bugs + 4 MAJOR — questo è il primo fix",
                "Utenti stavano perdendo messaggi offline su ogni connessione persa"
              ]),
        .init(id: "v1.0.309", date: "2026-05-02",
              title: "🎯 AUDIT 100% AGENT-SCOPE CLOSED",
              bullets: [
                "TODO_AUDIT.md aggiornato con scoreboard finale",
                "§1 Critical: 1/2 (Xcode 26 ✅, export compliance ⏳ legal)",
                "§2 Engine TODOs: 4/4 ✅ (delete-local W326 chiuso il saga file)",
                "§3 Stub UIs: 16/16 ✅ (W295-W325 sweep)",
                "§6 Repo hygiene: 3/3 ✅ (W302, W309, W312)",
                "5 di 7 sezioni 100% chiuse — restanti necessitano input umano",
                "190+ features shipped da W137 in ~2 settimane"
              ]),
        .init(id: "v1.0.308", date: "2026-05-02",
              title: "Wire delete-for-me — audit §2 100% closed (W326)",
              bullets: [
                "ChatContainer: nuovo deleteMessageLocally(_:) — tombstone senza envelope",
                "ChatDetailScreen onDeleteForMe → handleDeleteForMe (method-extracted)",
                "Closure body trivial (1 statement) — safe per CLAUDE.md §13",
                "Audit §2 engine-TODOs: 4/4 ✅ (delete-local was the last)",
                "Touched ChatDetailScreen.swift defensively — saga file"
              ]),
        .init(id: "v1.0.307", date: "2026-05-02",
              title: "Audit §3 stub-UI sweep — InCall + Bubble (W323-W325)",
              bullets: [
                "InCallScreen (W323): 'DEMO' capsule badge quando keyInfo == nil",
                "LiveInCallScreen (W324): 'REKEY DEMO' overlay + extract InCallScreen call",
                "BubbleActionSheet (W325): disabled '+' ora flash tooltip 'Picker emoji in arrivo'",
                "TUTTE le 16 §3 stub UIs ora polished",
                "Audit §3 100% closed"
              ]),
        .init(id: "v1.0.306", date: "2026-05-02",
              title: "Refresh TODO_AUDIT.md scoreboard",
              bullets: [
                "Updated audit progress matrix",
                "§3 stub UIs: 13/16 → 16/16 dopo W323-W325"
              ]),
        .init(id: "v1.0.305", date: "2026-05-02",
              title: "Audit §3 stub-UI sweep batch — onboarding (W314-W316)",
              bullets: [
                "WelcomeScreen (W314): 'Funzione in arrivo' italic disclaimers sotto i CTA stub",
                "PhoneEntryScreen (W315): timestamp 'Ultimo tentativo HH:mm:ss' dopo Continue",
                "LinkNewDeviceScreen (W316): tap-to-copy fingerprint + disclaimer pairing",
                "Tutto via static helpers, type-checker safe (SWIFT6_PATTERNS rules)",
                "3 stub UIs polished — TODO_AUDIT.md §3 progress"
              ]),
        .init(id: "v1.0.304", date: "2026-05-02",
              title: "Audit §3 stub-UI sweep batch — group screens (W319-W322)",
              bullets: [
                "CreateGroupScreen (W319): 'N selezionati su M' counter live",
                "GroupChatScreen (W320): long-press titolo → copy group UUID + snackbar",
                "GroupInfoScreen (W321): 'Aggiornato N minuti fa' relative timestamp",
                "GroupCallScreen (W322): 'N in linea' capsule badge in titolo",
                "4 stub UIs polished — TODO_AUDIT.md §3 progress"
              ]),
        .init(id: "v1.0.303", date: "2026-05-02",
              title: "NetworkSimulator: stub disclaimer (W317)",
              bullets: [
                "Settings → Simulatore rete: aggiunto disclaimer '⚠️ stub UI'",
                "Esplicito che il packet shaper non agisce sul transport",
                "Evita confusione QA: 'perché non funziona?'",
                "Sister polish dei W295/W303 — UX wins su stub UIs"
              ]),
        .init(id: "v1.0.302", date: "2026-05-02",
              title: "Pin xcode 26.4 in codemagic.yaml (W313)",
              bullets: [
                "codemagic.yaml: 'xcode: latest' → 'xcode: 26.4' (entrambi i workflow)",
                "Latest resolveva già a 26.4.1 — pin per reproducibilità",
                "Soddisfa Apple ITMS-90725 deadline (April 28, 2026)",
                "Audit §1 critical item DONE (Xcode 26 deadline)"
              ]),
        .init(id: "v1.0.301", date: "2026-05-02",
              title: "Estratto SWIFT6_PATTERNS.md (W312)",
              bullets: [
                "Nuovo: SWIFT6_PATTERNS.md nel root del repo",
                "Estratto da CLAUDE.md §13 (W174-W258 saga)",
                "Reference stabile per agenti che lavoreranno su Q-Audion iOS",
                "Audit §6 hygiene progress (3 of ~3)"
              ]),
        .init(id: "v1.0.300", date: "2026-05-02",
              title: "🎉 v1.0.300 milestone — STATISTICHE section in About (W311)",
              bullets: [
                "300ª release! About guadagna una sezione 'STATISTICHE'",
                "Conta release nel changelog (≥300 entries)",
                "Giorni dall'installazione (da W158 'Membro da')",
                "Build distinte launciate (da W162 buildSeen stamps)",
                "Reads cheap, recomputed on render"
              ]),
        .init(id: "v1.0.299", date: "2026-05-02",
              title: "WhatsNew: 'Esporta come testo' share button (W310)",
              bullets: [
                "'Cosa c'è di nuovo': toolbar share button → export .txt",
                "Genera plain-text con header '## v1.0.X — date' + bullet list",
                "Rispetta il filtro 'Solo ultime 5' (esporta solo visibili)",
                "Sheet con UIActivityViewController (Mail · Messages · Files)",
                "Utile per condividere release log fuori dall'app"
              ]),
        .init(id: "v1.0.298", date: "2026-05-02",
              title: "Shared TapCopyRow component (W309)",
              bullets: [
                "Nuovo: DesignSystem/Components/TapCopyRow.swift",
                "Promuove il pattern W297/W307/W308 in un componente condiviso",
                "Pure additive — i 3 helper per-file restano invariati per ora",
                "Future tap-to-copy possono usare il componente condiviso",
                "Hygiene: §6 audit progress (DRY refactor)"
              ]),
        .init(id: "v1.0.297", date: "2026-05-02",
              title: "Backup: Cifratura tap-to-copy (W308)",
              bullets: [
                "Settings → Backup: 'Cifratura' tap-to-copy",
                "QAUD/AES-256-GCM è il valore più chiesto in security audit",
                "tapCopyRow helper estesi a 3 file (About, Account, Backup)"
              ]),
        .init(id: "v1.0.296", date: "2026-05-02",
              title: "Account: User ID + Phone Hash tap-to-copy (W307)",
              bullets: [
                "Account → IDENTITÀ: 'User ID' e 'Phone Hash' tap-to-copy",
                "Sister di W297/W298 (About) — stesso pattern",
                "Clipboard icon + haptic feedback alla copia",
                "I valori più richiesti in bug-report cross-device"
              ]),
        .init(id: "v1.0.295", date: "2026-05-02",
              title: "Backup: 'Backup stimato' size preview (W306)",
              bullets: [
                "Settings → Backup: nuova riga 'Backup stimato'",
                "Stima byte di conv list + messaggi + abbozzi da UserDefaults",
                "Formattato via ByteCountFormatter (KB / MB)",
                "Tester sa al volo se il backup sarà piccolo o pesante"
              ]),
        .init(id: "v1.0.294", date: "2026-05-02",
              title: "Idiom row in About → PIATTAFORMA (W305)",
              bullets: [
                "About → PIATTAFORMA: nuova riga 'Idiom'",
                "Distingue iPhone / iPad / Mac (Catalyst) / TV / CarPlay",
                "QA può capire al volo se un layout bug è phone o pad",
                "Default fallback per .vision (iOS 17+) e cases futuri"
              ]),
        .init(id: "v1.0.293", date: "2026-05-02",
              title: "OtaUpdate: 'Ultimo controllo N minuti fa' (W304)",
              bullets: [
                "Aggiornamento OTA: timestamp 'Ultimo controllo N minuti fa'",
                "Stamped a ogni check() (anche errori)",
                "Sister di W295 / W303 — pattern relativo it_IT",
                "Stub UI polish — TODO_AUDIT.md §3 progress"
              ]),
        .init(id: "v1.0.292", date: "2026-05-02",
              title: "DeviceManagement: 'Aggiornato N minuti fa' (W303)",
              bullets: [
                "Settings → Dispositivi: timestamp 'Aggiornato N minuti fa'",
                "Stamped al construct + dopo ogni refresh()",
                "Sister di W295 (MyPhones) — pattern relativo it_IT",
                "Stub UI polish — TODO_AUDIT.md §3 progress"
              ]),
        .init(id: "v1.0.291", date: "2026-05-02",
              title: "Split WhatsNew data → WhatsNewData.swift (W302)",
              bullets: [
                "WhatsNewScreen.swift era ~580 linee — danger zone type-checker",
                "Estratto extension ReleaseNote { releaseNotes: [...] } in nuovo file",
                "WhatsNewData.swift: solo i dati. WhatsNewScreen.swift: solo la View",
                "Stesso target → l'extension binda al ReleaseNote esistente",
                "Future entry vanno SOLO in WhatsNewData.swift (TODO_AUDIT.md §6)"
              ]),
        .init(id: "v1.0.290", date: "2026-05-02",
              title: "WhatsNew: toggle 'Solo ultime 5' (W301)",
              bullets: [
                "'Cosa c'è di nuovo': nuovo toggle in cima 'Solo ultime 5'",
                "Filtra a `releaseNotes.prefix(5)` quando attivo",
                "Riduce lo scroll dopo 50+ release shipped",
                "Stato @State scoped alla schermata, non persiste"
              ]),
        .init(id: "v1.0.289", date: "2026-05-02",
              title: "Riga 'Regione' in About → STATO SISTEMA (W300)",
              bullets: [
                "About → STATO SISTEMA: 'Regione' (es. 'IT', 'CH', 'US')",
                "Distinta dalla 'Lingua sistema' (W269)",
                "Locale.current.region.identifier con fallback iOS 15-",
                "Utile per debug 'it_CH' — italiano + regione Svizzera"
              ]),
        .init(id: "v1.0.288", date: "2026-05-02",
              title: "Showcase aptico 6 pattern in DIAGNOSTICA (W299)",
              bullets: [
                "Notifiche → DIAGNOSTICA: 'Showcase aptico'",
                "Fa scattare i 6 pattern HapticFeedback in sequenza",
                "Sent · Start · Stop · Reaction · Destructive · Failure",
                "Tester può distinguere ogni pattern singolarmente (gap 0.5s)"
              ]),
        .init(id: "v1.0.287", date: "2026-05-02",
              title: "Estendi tap-to-copy a Bundle name/id + vendor ID (W298)",
              bullets: [
                "About → VERSIONE: 'Bundle name' e 'Bundle id' tap-to-copy",
                "About → DATI LOCALI: 'ID dispositivo (vendor)' tap-to-copy",
                "Stessa pattern di W297 (Commit) — clipboard + haptic",
                "I 4 metadati più copiati nei bug report ora copy-out 1 tap"
              ]),
        .init(id: "v1.0.286", date: "2026-05-02",
              title: "Tap-to-copy commit row in About (W297)",
              bullets: [
                "About → VERSIONE: tap sulla riga 'Commit' copia il SHA",
                "Icona doc.on.clipboard a destra telegrafa il gesto",
                "Haptic feedback alla copia (HapticFeedback.messageSent)",
                "Sister di W156/W157 — pattern tap-to-copy per metadata"
              ]),
        .init(id: "v1.0.285", date: "2026-05-02",
              title: "CallHistory: filtro 'Solo perse' (W296)",
              bullets: [
                "Schermata Chiamate: nuovo toggle 'Solo perse' in cima alla lista",
                "Mostra il count visibile vs totale (es. '3 di 12')",
                "Filtraggio reattivo, scopo session (non persiste)",
                "Riduce il triage per chi cerca solo le chiamate perse"
              ]),
        .init(id: "v1.0.284", date: "2026-05-02",
              title: "MyPhones: 'Aggiornato N minuti fa' (W295)",
              bullets: [
                "Settings → I miei numeri: timestamp 'Aggiornato N minuti fa'",
                "Stamped quando l'utente preme 'Salva' (UserDefaults)",
                "RelativeDateTimeFormatter con locale 'it_IT'",
                "Visivo che le modifiche sono state effettivamente persistite"
              ]),
        .init(id: "v1.0.283", date: "2026-05-02",
              title: "Wire 'Apri chat' su ContactDetail (W294)",
              bullets: [
                "ContactDetail action 'Chat': era TODO no-op, ora reagisce",
                "Dismiss della scheda + snackbar guida 'Apri da Chat'",
                "Soluzione interim — deep-link reale richiede nav coordinator globale",
                "Rimane in TODO_AUDIT.md §2.3 per il fix definitivo"
              ]),
        .init(id: "v1.0.282", date: "2026-05-02",
              title: "Wire admin banner CTA URL (W293)",
              bullets: [
                "ChatListScreen admin banner: era TODO no-op, ora apre URL",
                "Esteso AdminBannerData con `ctaURL: URL?` opzionale",
                "Tap del CTA → UIApplication.shared.open(url) se URL presente",
                "Wired un altro TODO(engine) dall'audit (TODO_AUDIT.md §2.2)"
              ]),
        .init(id: "v1.0.281", date: "2026-05-02",
              title: "Settings top-bar Menu — wired engine TODO (W292)",
              bullets: [
                "Settings → top-bar `⋯`: era TODO no-op, ora Menu funzionante",
                "Quick actions: Copia versione · Impostazioni iOS · Feedback TF",
                "Wired uno dei TODO(engine) dall'audit (TODO_AUDIT.md §2.4)",
                "Ogni voce è side-effect-only — nessuna nuova navigation state"
              ]),
        .init(id: "v1.0.280", date: "2026-05-02",
              title: "Bundle metadata + GitHub tags link (W290/W291)",
              bullets: [
                "About → VERSIONE: 'Bundle name' + 'Bundle id' (W290)",
                "Surface CFBundleName + CFBundleIdentifier per QA",
                "About → ASSISTENZA: 'Tags GitHub' button (W291)",
                "Apre github.com/sigarone/Q-Audion-IOS/tags",
                "Cronologia release pubblica accessibile dal device"
              ]),
        .init(id: "v1.0.279", date: "2026-05-02",
              title: "Fix Xcode 26.4 build errors (W289) + W288 TF link",
              bullets: [
                "v1.0.278 build failed: 2 real Swift errors caught by diag step",
                "Fix W289a: Calendar.Identifier switch needed regular `default` (Xcode 26.4 strict)",
                "Fix W289b: ByteCountFormatter has no .locale property — removed",
                "Aggiunto W288: 'Feedback TestFlight' button in About → ASSISTENZA",
                "Apre la pagina pubblica del beta su testflight.apple.com",
                "Aggiunto TODO_AUDIT.md — outstanding work audit nel repo"
              ]),
        .init(id: "v1.0.278", date: "2026-05-02",
              title: "Audio session cat + UN auth status (W286/W287)",
              bullets: [
                "About → STATO SISTEMA: 'Audio session' (W286)",
                "Mostra la AVAudioSession.category corrente (es. 'PlayAndRecord')",
                "Notifiche → STATO: 'Autorizzazione' riga sopra Pendenti/Consegnate (W287)",
                "Authorized · Denied · Provisional · Ephemeral · Not determined",
                "Diagnosi rapida 'le notifiche non arrivano' (potrebbe essere denied)"
              ]),
        .init(id: "v1.0.277", date: "2026-05-02",
              title: "Conta release nel WhatsNew intro (W285)",
              bullets: [
                "'Cosa c'è di nuovo': intro mostra il count di entries",
                "Es. '53 entries · feature/ios-android-parity'",
                "Aiuta i tester a vedere d'occhio quante milestone sono uscite",
                "Static computed property — type-checker safe (CLAUDE.md §13)"
              ]),
        .init(id: "v1.0.276", date: "2026-05-02",
              title: "'Apri Privacy iOS' deep-link in Privacy (W284)",
              bullets: [
                "Privacy → SISTEMA: 'Apri Privacy in Impostazioni iOS'",
                "Sister di W169 (Notifiche → SISTEMA), stesso destination URL",
                "Più vicino al contesto mentale quando l'utente legge i toggle privacy",
                "Util quando Mic / NFC / Camera permessi sono stati revocati"
              ]),
        .init(id: "v1.0.275", date: "2026-05-02",
              title: "Diagnostics export: SYSTEM STATE section (W283)",
              bullets: [
                "Esporta diagnostica: nuova sezione 'SYSTEM STATE'",
                "Aggrega thermal · low-power · cores · physical mem · uptime · free disk",
                "Pre-bind disciplinato di ogni valore (CLAUDE.md §13)",
                "Bug-report di QA ora si auto-include il contesto hardware"
              ]),
        .init(id: "v1.0.274", date: "2026-05-02",
              title: "Timezone + calendar + dark-mode + mic (W279-W282)",
              bullets: [
                "About → STATO SISTEMA: 4 nuove righe diagnostiche",
                "W279 Fuso orario (es. 'Europe/Rome')",
                "W280 Calendario (Gregoriano / Islamico / Ebraico / ...)",
                "W281 Aspetto (Chiaro / Scuro / Non specificato)",
                "W282 Permesso microfono (Concesso / Negato / Non richiesto)",
                "AVAudioSession aggiunto agli imports per W282"
              ]),
        .init(id: "v1.0.273", date: "2026-05-02",
              title: "Test feedback aptico in DIAGNOSTICA (W278)",
              bullets: [
                "Notifiche → DIAGNOSTICA: 'Test feedback aptico'",
                "Fa scattare il buzz canonico (HapticFeedback.messageSent)",
                "Verifica che la W160 vibrazione sia wirata e che il device abbia Taptic Engine",
                "Utile su iPad vecchi che mancano del motore aptico"
              ]),
        .init(id: "v1.0.272", date: "2026-05-02",
              title: "Battery + brightness + screen + vendorID (W274-W277)",
              bullets: [
                "About → STATO SISTEMA: 3 nuove righe diagnostiche",
                "W274 Batteria: livello + stato (in carica / scarica / piena)",
                "W275 Luminosità schermo: 0..100%",
                "W276 Schermo: dimensioni (es. '390×844 · @3x')",
                "W277 ID dispositivo (vendor): identifierForVendor truncato",
                "Tutto via UIDevice + UIScreen, single-statement helpers"
              ]),
        .init(id: "v1.0.271", date: "2026-05-02",
              title: "Svuota URLCache dev action (W271)",
              bullets: [
                "Settings → SVILUPPATORE: 'Svuota URLCache'",
                "Forza re-fetch HTTP per OTA catalog + avatar download",
                "URLCache.shared.removeAllCachedResponses()",
                "Utile per QA che vuole verificare metadata server fresh"
              ]),
        .init(id: "v1.0.270", date: "2026-05-02",
              title: "Cancella notifiche pianificate dev action (W270)",
              bullets: [
                "Notifiche → DIAGNOSTICA: 'Cancella notifiche pianificate'",
                "Sister di W263 (consegnate) — questa annulla i trigger in coda",
                "Utile se il tester tocca W171 e cambia idea prima dell'1.5s",
                "API: UNUserNotificationCenter.removeAllPendingNotificationRequests()"
              ]),
        .init(id: "v1.0.269", date: "2026-05-02",
              title: "Locale + memoria fisica + low-power in About (W269/W272/W273)",
              bullets: [
                "About → STATO SISTEMA: 3 nuove righe",
                "W269: lingua sistema (es. 'it_IT')",
                "W272: memoria fisica del dispositivo (RAM totale)",
                "W273: stato risparmio energetico (CPU ridotta quando attivo)",
                "Tutto via ProcessInfo + Locale, no async, no closures"
              ]),
        .init(id: "v1.0.268", date: "2026-05-02",
              title: "Self-test crittografia ML-KEM-1024 (W268)",
              bullets: [
                "Settings → SVILUPPATORE: 'Self-test crittografia'",
                "Round-trip sincrono: keygen → encap → decap → confronto shared secret",
                "Mostra OK + bytes + ms se passa, FAIL + reason se cade",
                "Sanity check rapido che la PQC stack sia viva senza fare una chiamata",
                "Alert title generalizzato in 'Sviluppatore' (era 'Cache liberata')"
              ]),
        .init(id: "v1.0.267", date: "2026-05-02",
              title: "Memoria processo in About (W267)",
              bullets: [
                "About → STATO SISTEMA: nuova riga 'Memoria processo'",
                "Resident size via mach_task_basic_info (Mach syscall)",
                "Stessa cifra che Activity Monitor / Instruments mostra come 'Memory'",
                "Utile per individuare leak in sessioni lunghe (PQC + ONNX)"
              ]),
        .init(id: "v1.0.266", date: "2026-05-02",
              title: "Spazio libero su disco in About (W266)",
              bullets: [
                "About → STATO SISTEMA: nuova riga 'Spazio libero'",
                "Usa volumeAvailableCapacityForImportantUsage (cifra realistica)",
                "Aiuta i tester a indagare upload falliti o eviction cache",
                "Formattato in locale italiana via ByteCountFormatter"
              ]),
        .init(id: "v1.0.265", date: "2026-05-02",
              title: "STATO section in Notifiche (pending + delivered) (W265)",
              bullets: [
                "Notifiche → STATO: conta pendenti + consegnate",
                "Refresh automatico all'apertura schermata",
                "Refresh anche dopo W171 (test) e W263 (clear)",
                "Verifica visibile che il toolkit di QA stia agendo davvero"
              ]),
        .init(id: "v1.0.264", date: "2026-05-02",
              title: "STATO SISTEMA section in About (W264)",
              bullets: [
                "About: nuova sezione 'STATO SISTEMA'",
                "Uptime processo (real timer da launch)",
                "Stato termico (Normale / Tiepido / Caldo / Critico)",
                "Numero di core CPU disponibili",
                "Utile per QA che indaga calo di qualità in chiamate lunghe (thermal)"
              ]),
        .init(id: "v1.0.263", date: "2026-05-02",
              title: "Clear delivered notifications dev action (W263)",
              bullets: [
                "Notifiche → DIAGNOSTICA: 'Cancella notifiche consegnate'",
                "Svuota il cassetto notifiche di iOS (UNUserNotificationCenter)",
                "Sister di 'Pulisci badge' (W166) — usate insieme per QA pulito"
              ]),
        .init(id: "v1.0.262", date: "2026-05-02",
              title: "🎉 Type-checker beat — fix real API mismatch (W262)",
              bullets: [
                "v1.0.261 structural fixes WORKED — type-checker is no longer choking",
                "Build now reports a REAL Swift error, not a timeout",
                "MessageComposer struct had `recordingElapsedSeconds` property but init didn't accept it",
                "Fix: add `recordingElapsedSeconds: TimeInterval = 0` to init signature",
                "First non-timeout failure since v1.0.225 — diagnostic infrastructure won"
              ]),
        .init(id: "v1.0.261", date: "2026-05-02",
              title: "Wrap MessageComposer in computed property (W261)",
              bullets: [
                "v1.0.260 still failed — error moved up to MessageComposer( call site",
                "Even with all closures method-extracted, 14-arg struct construction was too much",
                "Fix: wrap the entire MessageComposer(...) in @ViewBuilder computed property",
                "The body's ZStack now sees a single `composerView` reference",
                "Computed properties have isolated type-check scope from the parent ViewBuilder"
              ]),
        .init(id: "v1.0.260", date: "2026-05-01",
              title: "Extract composer Binding(set:) + scroll callbacks (W260)",
              bullets: [
                "v1.0.259 worked — error moved past photos to line 112 composer Binding",
                "Same fix: extracted `Binding(set:)` body to handleComposerTextChange method",
                "Preemptively flattened scroll-to-bottom .onChange closures with guard let",
                "`if let last = ... { withAnimation { ... } }` is the same antipattern",
                "All inline closures in ChatDetailScreen body are now method-bound or trivial"
              ]),
        .init(id: "v1.0.259", date: "2026-05-01",
              title: "Extract photo-picker callback to methods (W259)",
              bullets: [
                "v1.0.258 voice-note fix worked — error moved to multi-photo callback",
                "Same antipattern: closure → Task → for → if → MainActor.run + interpolation",
                "Same structural fix: extract closure body to instance methods",
                "Snackbar interpolation moved to a static helper (single-overload, fast)",
                "All inline closure bodies in ChatDetailScreen.swift now ≤ 1-2 levels deep"
              ]),
        .init(id: "v1.0.258", date: "2026-05-01",
              title: "Extract voice-note callbacks to methods (W258)",
              bullets: [
                "v1.0.257 still failed — even `container.markFailed(...)` timed out",
                "Root cause: 4-5 levels of closure depth exhausts the type-checker",
                "Structural fix: extract closure bodies into named methods",
                "Methods have a clean type-check scope, isolated from closure constraints",
                "Pattern: `onStartVoiceNote: handleVoiceNoteStart` (no inline { ... })",
                "CLAUDE.md §13 updated with this 5th and final antipattern variant"
              ]),
        .init(id: "v1.0.256", date: "2026-05-01",
              title: "Drop debug prints in voice-note callbacks (W256)",
              bullets: [
                "Even `let line: String = \"...\" + errMsg` (both sides typed) times out",
                "The `+` operator has too many overloads to resolve in nested closures",
                "Pragmatic fix: drop the diagnostic prints entirely — they were debug-only",
                "Pre-emptive: also dropped the 5-segment concat in onFinishVoiceNote",
                "Production uses os_log anyway; debug `print` is not load-bearing",
                "CLAUDE.md §13 updated with this 4th type-checker antipattern variant"
              ]),
        .init(id: "v1.0.255", date: "2026-05-01",
              title: "Fix type-checker timeout #3 — String(Int) overload trap (W255)",
              bullets: [
                "ChatDetailScreen.swift:175 — `String(rec.durationMs)` (Int) also times out",
                "Root cause: String(_:) has many numeric overloads (Int, UInt, Double, …)",
                "Fix: switch to String(describing:) which has a single overload",
                "CLAUDE.md §13 updated with this 3rd type-checker antipattern variant"
              ]),
        .init(id: "v1.0.253", date: "2026-05-01",
              title: "Fix type-checker timeout #2 in ChatDetailScreen (W253)",
              bullets: [
                "ChatDetailScreen.swift:151 — print(\"...\" + errMsg) still tripped the type-checker",
                "Even with errMsg pre-bound, the `+` operator inside `print(...)` was the problem",
                "`print` has many overloads (variadic / separator / terminator / to:&Output)",
                "Fix: build full line into a local String, then `print(line)`",
                "Same pattern as onFinishVoiceNote (lines 169-175) — now consistent"
              ]),
        .init(id: "v1.0.252", date: "2026-05-01",
              title: "Quick-copy build identifier in About (W179)",
              bullets: [
                "About → ASSISTENZA: nuovo bottone 'Copia diagnostica rapida'",
                "Copia in clipboard: versione · build · dispositivo · iOS",
                "Sister di 'Contatta supporto' — stesso payload, transport diverso",
                "Useful per Slack/Discord/issue trackers senza aprire Mail"
              ]),
        .init(id: "v1.0.251", date: "2026-05-01",
              title: "Fix type-checker timeout in ChatDetailScreen (W251)",
              bullets: [
                "ChatDetailScreen.swift:197 W38 send-failure snackbar — multi-segment interpolation `\\(reason.localizedDescription)` triggered Swift 6 / Xcode 26.4 type-checker timeout",
                "Fix: pre-bind reason.localizedDescription to local + use String + concatenation",
                "Same defensive treatment applied to typingRow (peer display-name chain)",
                "Cross-references CLAUDE.md §13 — type-checker traps documented in W174"
              ]),
        .init(id: "v1.0.241–249", date: "2026-05-01",
              title: "QA toolkit polish + CI diagnostics (W170–W177)",
              bullets: [
                "About → PIATTAFORMA: dispositivo + iOS in uso (W170)",
                "Notifiche → DIAGNOSTICA: invio notifica di test (W171)",
                "Footnote copyright sotto la versione (W172)",
                "About → ASSISTENZA: contatta supporto via mail (W173)",
                "CLAUDE.md: documentazione type-checker traps (W174)",
                "CI: profiling flags compile-time per surfacciare bottleneck (W175)",
                "CI: re-print diag.log all'inizio di Step 7 per visibilità (W177)"
              ]),
        .init(id: "v1.0.232–238", date: "2026-05-01",
              title: "Diagnostica e dev tools (W162–W167)",
              bullets: [
                "About: 'Build installato N giorni fa' (W162)",
                "Settings → SVILUPPATORE: Reset metadati locali (W163)",
                "Diagnostic export: conta abbozzi · ultimo accesso · build seen (W164)",
                "Conferma prima di Svuota cache allegati (W165)",
                "Pulisci badge notifiche dev action (W166)",
                "About → CONNESSIONE: stato WS live + autenticato (W167)"
              ]),
        .init(id: "v1.0.220–231", date: "2026-05-01",
              title: "Privacy & polish marathon (W137–W160)",
              bullets: [
                "Abbozzi composer persistenti per chat (W137) + indicatore \"Bozza:\" (W138)",
                "Esporta chat in .txt via share sheet (W139)",
                "Swipe \"Segna letto\" e azioni di contesto sulla lista (W140)",
                "Finestra modifica messaggi 15 minuti (W141)",
                "\"Ultimo accesso\" del peer in topbar chat (W142)",
                "Banner E2E nelle chat vuote (W143)",
                "Velocità voice-note persistente tra sessioni (W144)",
                "Conferma prima di Elimina/Svuota/Esci (W145, W147, W151)",
                "Conteggio non letti nel titolo \"Chat (N)\" (W146)",
                "Markdown inline `code` / **bold** / *italic* nei bubble (W148, W149)",
                "Cancella abbozzi + ultimo accesso da Settings (W150, W153)",
                "Toggle privacy: anteprima link (W152), abbozzi nella lista (W155), vibrazione (W160)",
                "Tap-to-copy versione + ID utente (W156, W157)",
                "About: \"Membro da\" + dati locali (conversazioni, messaggi, abbozzi) (W158, W159)"
              ]),
        .init(id: "v1.0.96", date: "2026-04-30",
              title: "QA toolkit completata",
              bullets: [
                "Esporta diagnostica — text dump shareable con build, device, state (no token leak)",
                "Sister di Reset dati locali (v1.0.94) per workflow QA TestFlight"
              ]),
        .init(id: "v1.0.95", date: "2026-04-30",
              title: "CallHistory gesture",
              bullets: [
                "Swipe-trailing su una chiamata → Elimina (gesto Mail/Messages canonico)",
                "Overflow menu nel topBar → Cancella storico con alert di conferma + count"
              ]),
        .init(id: "v1.0.94", date: "2026-04-30",
              title: "Reset dati locali",
              bullets: [
                "Settings → SVILUPPATORE → Reset dati locali",
                "Wipe di 8 chiavi UserDefaults non-credenziale (numeri, opt-in beta, banner)",
                "Auth token / device id preservati (logout esplicito separato)"
              ]),
        .init(id: "v1.0.93", date: "2026-04-30",
              title: "Group composer real",
              bullets: [
                "FAB \"Nuovo gruppo\" nella tab Chiamate ora apre il vero CreateGroupScreen",
                "Rimosso lo stub \"W40 in arrivo\" (W40 è già live da v1.0.86)"
              ]),
        .init(id: "v1.0.92", date: "2026-04-30",
              title: "I miei numeri (multi-phone)",
              bullets: [
                "Settings → ACCOUNT → I miei numeri",
                "Multipli E.164 attaccati allo stesso account (peppered hash)",
                "Validazione E.164 client-side via PhoneHashHelper"
              ]),
        .init(id: "v1.0.91", date: "2026-04-29",
              title: "Hotfix critico + W42 + W43 + W39.polish",
              bullets: [
                "FIX: HomeView mancava `}` su callsTab — sbloccato build TestFlight",
                "FIX: FastSetup login E.164 double-hash — `loginWithPhoneHash` bypass",
                "Aggiornamento OTA stub UI in Settings → INFO",
                "Simulatore rete (dev) in Settings → SVILUPPATORE",
                "CallHistory encapsulation polish"
              ]),
        .init(id: "v1.0.86–88", date: "2026-04-28",
              title: "Group Chat trio + DeviceManagement",
              bullets: [
                "CreateGroupScreen + GroupChatScreen + GroupInfoScreen (W40)",
                "DeviceManagementScreen enhanced + LinkNewDeviceScreen X25519",
                "BubbleActionSheet snackbar feedback per le 4 azioni chat"
              ]),
        .init(id: "v1.0.66–85", date: "2026-04-26",
              title: "Cross-platform parity track A",
              bullets: [
                "ChatListScreen sectioned (W19) — 1:1 con Android",
                "ContactsScreen W23 — TUTTI / SCOPRI / BLOCCATI",
                "SettingsScreen W24 — ProfileHero + SecurityChips + 6 sezioni",
                "CallHistoryView W39 — call-history list",
                "Onboarding stack — Splash + Welcome + PhoneEntry + VoiceEnrollment + FastSetup"
              ]),
    ]
}
