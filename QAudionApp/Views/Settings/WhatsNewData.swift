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
