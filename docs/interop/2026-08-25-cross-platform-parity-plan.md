# Piano di parità cross-platform — stack chiamate Q-Audion (iOS + Desktop verso la baseline Android)

Documento interno di design. Stato al 2026-08-25. Fonti: inventari per-piattaforma (file e righe citati sono stati verificati sui repo reali alla data del documento), contratti wire del server deployato (`cmd/bcrypto-lite`, graph-verified), memoria di progetto. Dove un'affermazione non è verificata è marcata esplicitamente UNAUDITED o "non evidenziato".

---

## 1. Scopo e principio

Android è oggi la piattaforma di riferimento dello stack chiamate: negli ultimi cicli ha accumulato correzioni di protocollo, invarianti di robustezza e lezioni pagate su device reali che iOS e desktop non hanno ancora. Questo documento inventaria ogni divario, lo classifica, e definisce il piano per chiuderlo lavorando iOS e desktop in parallelo.

La classificazione governa il metodo di porting, e va rispettata alla lettera:

Wire-protocol — parità 1:1 obbligatoria, byte-identica. Formati di envelope, prefissi opachi, tag di capability, semantiche di campo: qui non esiste "equivalente funzionale", esiste solo identico. Un byte di deriva nella derivazione chiavi video produce video nero senza fallback (vedi sframe-v1); un tag scritto diverso non interseca mai. Ogni item wire porta nel piano la specifica esatta dei campi, presa dal contratto server già deployato.

Invariante comportamentale — l'invariante è obbligatorio, il meccanismo è libero per piattaforma. La lezione fondante è quella del playout a 60 ms: Android risultò immune al bug non per progetto ma per come si comporta AudioTrack — pura fortuna di piattaforma. La conclusione, già registrata come regola di progetto: un invariante condiviso va scritto come frase testabile e testato su ogni piattaforma, anche quando l'API sottostante sembra renderlo "gratis". Esempio: l'invariante jitter non è "porta il buffer Android", è "il ritardo di playout accumulato viene recuperato senza drop udibili e resta limitato a 600 ms" — su iOS si realizza con time-stretch nel jitter buffer esistente, su desktop richiede di costruire il buffer da zero.

Piattaforma-specifico — escluso dal porting, con motivo scritto. Oggi un solo item: la strumentazione diagnostica Android (split del ritardo, relay-url nel drawer). Non ha impatto wire né di correttezza; resta però la nota dell'audit latenza: senza strumentazione equivalente, i report di latenza da iOS/desktop sono di fatto non debuggabili — è un prerequisito di osservabilità, non di interop (vedi Fase E).

Server-side-done — il lato server è già deployato; resta solo l'obbligo client. Questi item sono i più economici del piano: spesso un campo e un handler.

Un principio trasversale: dove l'assenza di una feature su iOS/desktop è una decisione deliberata e documentata (la posizione di sicurezza del desktop su audio-srtp, la condizione (b) non soddisfatta sul dc-mux iOS), il piano NON la tratta come lavoro arretrato da smaltire. La decisione va risolta esplicitamente prima di scrivere codice, e la risoluzione va registrata.

---

## 2. Matrice di parità completa

Legenda stato: presente / parziale / assente / n.a. Priorità: P0 = chiude chiamate o rompe video oggi; P1 = degrado reale misurabile su chiamate miste oggi; P2 = contingente, cosmetico, o a rischio solo futuro.

| Item | Tipo | iOS | Desktop | Rischio interop (sintesi) | Prio |
|---|---|---|---|---|---|
| sframe-v1-video-e2ee | wire | presente (nativo, default 1:1) | parziale (dialetto JS custom) | Se la derivazione JS desktop devia di un byte, video misto nero OGGI (Android fail-close). Serve verifica live + KAT, non porting | P0 |
| W-ACTIVECALLASSERT | wire | assente | assente | Ogni riconnessione WS mid-call arma il teardown di grazia del server: le chiamate miste muoiono a ogni blip iOS/desktop. Un campo + un check | P0 |
| audio-srtp-v1 | wire | assente (blocker tecnico) | assente (per policy W574d) | Sicuro per costruzione (intersezione mai vera); audio misto resta su DC/WS-relay: niente NetEQ/NACK, latenza e loss peggiori. Decisione di policy prima del porting | P1 |
| dc-hangup-v1 | wire | assente | assente | Terzo canale di hangup inesistente su chiamate miste; desktop senza backstop può restare in chiamata indefinitamente | P1 |
| W-HANGUPECHO+W-HANGUPPARK | invariante | parziale | assente | Hangup perso durante blip WS → il peer Android aspetta il watchdog 90s, il server chiude solo per grazia/recall | P1 |
| hangup-opaque-piggyback | wire | parziale (parse sì, emit no) | presente | Hangup iOS affidato al solo envelope call_hangup, che il server in certi path scarta: può svanire proprio negli scenari per cui il prefisso esiste | P1 |
| W-PLPFEEDBACK | wire | assente | assente | Loop FEC aperto su entrambi i lati delle chiamate miste: encoder Opus con expected-loss congelato → audio peggiore su link con perdita | P1 |
| W-FECDECODE | invariante | assente (documentato) | assente | Android paga ridondanza FEC che il ricevitore non decodifica mai: banda sprecata, ogni frame perso diventa concealment | P1 |
| W-BWCAP-vbwcap | wire | assente | assente | Cap video receiver-driven assente in entrambe le direzioni: sender che sovraccaricano downlink vincolati. Prefisso ignorato senza rotture | P1 |
| W-SETUPRETRY | invariante | parziale (solo PQC OFFER) | assente | Un call_answer/accepted perso su link instabile fallisce l'intero setup misto senza ritrasmissione | P1 |
| W-GLARE | wire | assente | assente | Chiamata reciproca cross-platform: tiebreak Android contro busy-reject peer → entrambe le chiamate possono morire. Raro ma deterministico | P1 |
| W-OFFERTS | wire | assente | assente | Offerte ribufferizzate squillano a piena forza dopo che il chiamante ha rinunciato (phantom ring). Il campo è già sul wire | P1 |
| W-MEDIADEAD | invariante | assente | assente | Peer morto (crash, tutti i canali persi) → zombie call silenziosa indefinita su iOS/desktop; Android chiude a 90s | P1 |
| http2-zombie-pool | invariante | assente | assente | Dopo handoff di rete la REST del handshake cavalca connessioni pool morte fino al timeout → setup lento/fallito proprio al cambio rete | P1 |
| W-SILENTPATHDEATH | invariante | assente (zero restartIce) | assente | NAT rebind senza evento OS: la gamba iOS/desktop resta morta; iOS non ha alcun path di ICE restart nemmeno su handoff WiFi→cellulare | P1 |
| W-JBADAPT+W-JBSTRETCH | invariante | parziale (no time-stretch) | assente (nessun jitter buffer) | Desktop accumula slip di playout in secondi o suona buchi; iOS recupera droppando frame udibili da 60 ms | P1 |
| W-JITTERCAP | invariante | presente | assente | Ritardo playout desktop cresce senza limite su reti cattive — esattamente il bug Android pre-068ec6d32, vivo oggi | P1 |
| W-MISSEDEVT (call_missed) | wire | parziale (replay durabile da verificare) | assente | Chiamate perse con desktop offline >60s non emergono MAI all'utente — perdita silenziosa visibile oggi. Server completo | P1 |
| W-WSQUEUECAP | invariante | parziale | assente | Relay WS desktop su link in stallo accumula secondi di audio STALE e li scarica al peer al recovery; può affamare il socket di signaling | P1 |
| W-KFFAST | invariante | assente (meccanismo ora disponibile) | parziale (via watchdog lento) | Dopo rekey/burst di perdita, video congelato per secondi in più rispetto ad Android prima del recovery | P1 |
| W-AES256DIAG (lezione leak) | invariante | assente (UNAUDITED) | assente (UNAUDITED) | Sicurezza, non interop: la classe di leak "chiave in chiaro nei log" non è mai stata auditata sui path E2EE di iOS/desktop | P1 |
| W-SRTPFALLBACK | invariante | assente | assente | Nessun rischio oggi (non c'è SRTP da cui degradare); obbligatorio day-one con qualunque porting di audio-srtp-v1 | P2 |
| W-SRTPPTIME | wire | assente | assente | Nessun rischio oggi; senza, un futuro SRTP iOS/desktop negozierebbe 20 ms contro i 60 pinnati Android → 3x packet rate. Da legare a audio-srtp-v1 | P2 |
| ice-batch-v1 | wire | assente | parziale (buffer RX esiste) | Le chiamate miste restano sulla forma legacy (funziona); perse le rimozioni di candidati (stale nei loro agent ICE) e il coalescing | P2 |
| W-OFFERGLARE | wire | parziale (upgrade-glare fatto) | parziale (idem) | Unilaterale oggi (solo Android manda restart-offer). Da portare 1:1 insieme alla loro futura macchina di ICE restart | P2 |
| W-AUTHSOCKET | invariante | presente | presente | Nessuno — l'invariante di identità socket tiene già su entrambe | P2 |
| W-RESTARTOFFERPARK | invariante | assente (prerequisito assente) | assente (idem) | Contingente: senza ICE restart non significa nulla; poi diventa necessario (park 45s sotto il ceiling 60s server) | P2 |
| W-DEADCALLACK | invariante | parziale | parziale | In gran parte chiuso lato server (W-STALEOFFER); residuo: auto-ACK client di signaling opaco replayato per chiamate appena finite | P2 |
| W-ROUTECLAMP | invariante | assente | assente | Dopo demozione Direct→Relay i sender tengono bitrate da tier direct → video misto choppy su TURN + carico flotta inutile | P2 |
| W-TURNSUSPECT | invariante | parziale (refresh hook, trigger debole) | assente | Credenziali TURN scadute degradano silenziosamente ogni chiamata mista che richiede relay, fino a restart/TTL | P2 |
| W-BACKPRESSURE | invariante | assente | assente | Encoding CPU-bound degrada caoticamente (frame drop) invece di scalare il ladder: video a scatti verso il ricevitore Android | P2 |
| W-ADAPTFORMAT | invariante | parziale (UNAUDITED) | parziale (UNAUDITED) | SE il ladder riavvia la capture per gradino, ogni adattamento blocca il video uscente. Item di audit, non gap confermato | P2 |
| W-SCREENPROFILE | invariante | parziale (UNAUDITED) | parziale (UNAUDITED) | Screenshare: testo condiviso illeggibile se il profilo forza 16:9 o sacrifica risoluzione. Item di audit | P2 |
| W-OFFLINEPARK | invariante | parziale | parziale | Solo batteria/churn, nessuna rottura chiamate; verificare che i retry non brucino in modalità aereo | P2 |
| W-PINGRTT | invariante | presente | parziale | Solo parità diagnostica, nessun impatto interop | P2 |
| W-INFLIGHTCANCEL | invariante | assente | parziale | Richieste post-handoff cavalcano il path morto fino a timeout; si porta insieme a http2-zombie-pool | P2 |
| W-CALLPHASES+W-CALLCUES | invariante | assente (presunto) | assente (presunto) | Solo UX (ringback a t=0, indicatore reconnecting). VINCOLO: suono di riconnessione rimosso per ordine utente — solo pill visiva | P2 |
| W-ENDREASONS | invariante | parziale (UNAUDITED) | parziale (UNAUDITED) | Cronologie chiamate incoerenti tra device (decline mostrato come hangup) — cosmetico | P2 |
| server-call-fixes-bundle | server-done | presente | presente | Nessun rischio trovato — hangup/cancel idempotenti su entrambe, che è tutto ciò che il bundle server richiede | P2 |
| W-RELAYFLEET (lato client) | server-done | presente (spot-check dovuto) | presente (caveat bridge) | Flotta visibile a entrambi; minori: bridge WSS-TURN desktop prende credenziali solo da relays[0]; parser iOS da verificare su porte-stringa e node_id | P2 |
| aprof-60x256-long-audio | wire | presente (1.0.959) | presente (default incondizionato) | Negoziazione completa ovunque. Residuo: copertura live sottile sul playout 60 ms desktop; invariante "il consumer audio non si affama mai" da testare per piattaforma | P2 |
| dc-mux-v1 | wire | parziale (codato, advertise OFF per decisione utente) | presente (path primario) | Audio iOS↔tutti resta su WS relay (carico server + latenza). NON flippare lo switch come chore di parità: condizione (b) è decisione deliberata, va risolta prima | P2 |
| W-DELAYSPLIT+W-RELAYID | piattaforma-specifico | n.a. | n.a. | Non è un item di porting; ma l'osservabilità equivalente è prerequisito per debuggare i report di latenza iOS/desktop | P2 |

---

## 3. Piano di esecuzione — iOS e desktop in parallelo

Le fasi sono ordinate per dipendenza, non per gusto: A sblocca le fondamenta wire su cui B–E poggiano. Dentro ogni fase i due binari (iOS, desktop) procedono in parallelo — nessun item di una piattaforma dipende dall'altra piattaforma, solo dal server (già deployato) e da Android (già in main). Ogni fase si chiude con un test interop live, non con "il codice compila": la regola di progetto è verificare l'artefatto spedito, non il sorgente, dopo tre difetti nello stesso giorno invisibili dal codice.

Formato: per ogni fase → item di lavoro per repo a livello file, note di compatibilità wire (cosa succede misto vecchio/nuovo), test live di chiusura.

### Fase A — Fondamenta wire P0: capability, asserzione di chiamata attiva, parsing relay, gestione stale/late, verifica sframe

Questa fase contiene i due P0 e gli item wire più economici (server già pronto). Nessun item di questa fase richiede più di poche decine di righe per client; il grosso del costo è la verifica live.

A1 — Registro capability tag speculare (W-CAPTAGS-REGISTRY).
La negoziazione è pura intersezione simmetrica degli array `capabilities` (stringhe) che ogni peer mette su call_offer/call_answer. Il server è cieco per contratto: non li vede, non li valida, non li riordina — pinnato dai test su tutti e quattro i path di delivery (diretto, call_answer, redelivery bufferizzata, fanout cluster), inclusi tag malformati e sconosciuti passati verbatim. Registro completo da rispecchiare byte-exact (fonte: `CallCapabilities.kt:54-470` in qaudion-android-new): `sframe-v1`, `sframe-aes256-v1`, `ratchet-v3`, `ratchet-v4` (flag-gated), `vkey-v1`, `dc-mux-v1`, `upgrade-intent-recv-v1`, `aprof-60x256-recv-v1`, `aprof-60x256-v1` (entrambi trattenuti su chiamate earbud), `audio-srtp-v1` (mai su earbud), `ice-batch-v1`, `dc-hangup-v1`, `earbud-relay-v1`. Chiave mancante = lista vuota = peer legacy; tag sconosciuti si ignorano nell'intersezione, mai rifiutati.
- iOS: `CallCapabilities.swift` — aggiungere le costanti mancanti (`ice-batch-v1`, `dc-hangup-v1`, e le audio quando le rispettive fasi le implementano); disciplina: la costante entra nel file SOLO insieme all'implementazione, l'advertise parte spento.
- Desktop: `CallCapabilities.ts:248-263` — idem.
- Compatibilità mista: totale per costruzione — un tag non pubblicizzato non interseca mai; è esattamente il motivo per cui questo registro va tenuto disciplinato e mai "pre-popolato".

A2 — `active_call_id` sull'authenticate (W-ACTIVECALLASSERT, P0 — l'item a più alto valore dell'intero piano).
Contratto esatto (W-AUTH-OPTFIELDS + W-LATERECONNECT, server deployato `cmd/bcrypto-lite/main.go:7187-7580`): il frame `authenticate` accetta, oltre a `token`: `active_call_id` (string — la chiamata che il processo crede ancora viva), `device_suffix` (string, `^[a-z0-9]{1,16}$`, namespace per companion device), `bin_relay` (*int tri-stato: assente = testo per sempre; 0 esplicito = veto terminale al downgrade; 1 = richiesta — il grant è SOLO l'eco `"bin_relay":1` nella risposta `authenticated`, e il socket passa a binario solo dopo che l'eco è effettivamente accodato), `bin_relay_video` (*int, concesso solo se il binario audio è concesso sullo STESSO frame e valore==1), `ent_epoch` (*uint64, doorbell entitlements). Regola non negoziabile: mai latchare `bin_relay` attraverso i socket — l'eco è per-connessione.
Semantica lato teardown: alla riconnessione, il teardown di grazia pendente (20s, ceiling adattivo 60s) viene cancellato SOLO se `active_call_id` combacia esattamente con la chiamata tracciata dal server; asserzione assente o sbagliata = il timer prosegue e la chiamata muore. Se il client asserisce una chiamata che il server non traccia più, il server consulta `recentCallEndings` (TTL 2 minuti; reason `peer_disconnected` da scadenza grazia, reason del client o `peer_hangup` da hangup esplicito, `"recall"` da recall stessa coppia; non consumato alla lettura, così ogni device multi-device riceve la risposta) e risponde con un semplice `call_hangup {call_id, reason}` sul socket fresco. Obbligo client: (1) inviare sempre `active_call_id` quando si detiene stato di chiamata viva; (2) trattare un `call_hangup` che arriva subito dopo `authenticated` come teardown definitivo per quel call_id — è il normale handler call_hangup, nessun codice speciale.
- iOS: `BCryptoWebSocketClient.swift`, `authenticate()` righe 1529-1541 — oggi il frame è `{token, bin_relay?}` e basta; grep repo-wide `active_call_id` = 0. Aggiungere il campo, alimentato dallo stato chiamata corrente.
- Desktop: `BCryptoSocket.ts`, `handleOpen` authData righe 1213-1216 + `AuthenticateData` in `messages.ts:170-185`.
- Compatibilità mista: un client vecchio semplicemente non asserisce e resta esposto al comportamento attuale; nessuna interazione col peer.

A3 — Consumo ice-batch-v1 (W-ICEBATCH).
Forma legacy: `candidate`, `sdp_mid`, `sdp_mline_index` top-level, un envelope per candidato. Forma batch (solo quando ENTRAMBI i peer hanno pubblicizzato `ice-batch-v1`): array `candidates` di `{candidate, sdp_mid?, sdp_mline_index?, removed:true?}` — `removed:true` è una rimozione che il ricevitore pota immediatamente; quando `candidates` è presente i campi top-level sono vuoti e VANNO ignorati. Il server non c'entra: call_ice viaggia sull'opaque relay F4 party-scoped, la forma batch è puramente end-to-end. Regola permanente: i ricevitori accettano ENTRAMBE le forme per sempre.
Ordine consigliato: prima il lato RX (consumo), poi advertise del tag, TX batch opzionale in coda — il valore reale per l'interop è ricevere le rimozioni di Android.
- iOS: `BCryptoCallingApiImpl.swift:199-231` (oggi codec per-candidato) + costante in CallCapabilities.
- Desktop: buffering RX pre-remoteDescription già esistente (`PeerConnectionManager.ts:148-154`); encode/decode batch + tag in `CallController.sendLocalIce:3702-3727`.
- Compatibilità mista: finché il tag non è pubblicizzato, tutto resta legacy per costruzione (funziona oggi). Nessun rischio di transizione.

A4 — Hardening del parsing relays multi-gruppo (W-RELAYFLEET lato client).
`GET /api/v1/calling/relays` ritorna `{relays:[gruppo,...]}` più opzionali top-level `wss_turn_url`, `masque_url`, `onion_address/onion_port`. Gruppo 1 (TURN control-plane): `type:"turn"`, hostname (IP esterno raw), porta 3478 come NUMERO, username/password/credential(alias)/ttl, urls `[stun:, turn:udp, turn:tcp` sul PublicHostname, più `turns:` solo se il listener TLS è bound]; gruppo 2 ripete con url a IP-literal; gruppi 3..n (uno per exit node VPN fresco) hanno una chiave EXTRA `node_id`, hostname = IP del nodo, porta come STRINGA (esce da SplitHostPort), urls solo `stun:`+`turn:udp`, stesse credenziali HMAC time-limited (segreto TURN condiviso fleet-wide). Un parser DEVE tollerare: numero arbitrario di gruppi, `node_id` presente su alcuni e assente sul primo (asserito dai test server), porta numero O stringa, lunghezze diverse delle liste url, chiavi sconosciute ovunque — appiattire tutti i gruppi e lasciare che ICE elegga per RTT misurato.
- iOS: parser già mappa ogni gruppo (`QAudionPeerConnectionFactory.swift:82-88`) — spot-check dovuto su gruppi 3..n: porte-stringa e chiave `node_id` non devono far fallire il decode.
- Desktop: `Application.getIceServers` mappa ogni gruppo (righe 8380-8384) — fix puntuale: `WssTurnBridge` prende le credenziali solo da `relays[0]` (riga 8315); la gamba di fallback bridge ignora le credenziali dei nodi flotta.

A5 — Gestione client di stale-offer e late-hangup (W-STALEOFFER + W-LATERECONNECT + W-CALLHANGUP-SEMANTICS).
Il server (deployato) risponde a una re-offer per una chiamata non più tracciata ma presente in recentCallEndings con un `call_hangup {call_id, reason}` definitivo al MITTENTE, e scarta l'offerta invece di ri-tracciare/ri-squillare. Obblighi client da implementare/verificare su entrambe le piattaforme: (1) un call_hangup ricevuto in risposta alla propria re-offer = smontare la chiamata fantasma, NON ritentare ICE; (2) mappa dei reason: qualunque call_hangup per il proprio call_id attivo = teardown definitivo a prescindere dalla stringa; `peer_disconnected` = fine per perdita di connessione (anche il reason dei replay W-STALEOFFER/W-LATERECONNECT); `recall` = superata da nuova chiamata della stessa coppia; `peer-acknowledged` è un'eco di bookkeeping EMESSA dal client (oggi solo Android) che può arrivare in ritardo e NON deve alzare UI. Nota di autorizzazione: call_hangup è F4 party-authorized — il peer deriva dalla chiamata tracciata, `recipient_id` è ignorato; un call_id fornito ma non tracciato viene scartato (fix stale-hangup-hijack), quindi tutto il path è idempotente e echi/duplicati sono no-op silenziosi.
- iOS: verifica dell'handler call_hangup esistente contro questa mappa (l'idempotenza c'è già, H-6); aggiungere la tolleranza a `peer-acknowledged`.
- Desktop: idem su `CallController.ts` (branch di ricezione :4846-4854).

A6 — Gate di età dell'offerta (W-OFFERTS, phantom ring).
Il server inietta `server_ts_ms` (unix millis di ricezione lato server) su ogni `call_incoming` relayato; un'offerta bufferizzata per push-wake conserva lo stamp ORIGINALE (`storedAt`) alla redelivery — quindi il campo può legittimamente essere più vecchio di "adesso", ed è esattamente il caso da gateare. Contratto call_offer completo per chi tocca questi handler: campi parsati `recipient_id` (può essere un'estensione numerica — il server risolve a UUID e riscrive `recipient_id` nel payload relayato), `call_id`, `call_type`, `has_video`, `caller_display` (auto-riempito con l'estensione del chiamante se omesso); gate video-entitlement su `has_video` OR EqualFold(call_type,"video"); il server rilancia l'intera mappa opaca come `call_incoming` (mai echo di tipo call_offer) iniettando `sender_id` e `server_ts_ms`; l'array `capabilities` va DENTRO la mappa data di offer/answer.
- iOS: handler call_incoming in `AppState` (~riga 4643) — grep `offerAge` = 0 oggi. Gate: se l'età supera la soglia (allineare la costante ad Android), niente ring a piena forza.
- Desktop: `CallIncomingData` (`messages.ts:987-1008`) oggi SCARTA `server_ts_ms` nel decode — aggiungere il campo; gate in `handleCallIncoming:5119`.
- Compatibilità mista: il campo è già su ogni offerta relayata; W-CANCELINVALIDATE server copre solo i cancel espliciti — le redelivery da scadenza/riconnessione continuano a squillare fantasma finché il gate client non esiste.

A7 — Verifica sframe-v1 (P0 — verifica, non porting).
Stato: iOS è passato al cryptor nativo byte-identico ad Android (`NativeVideoFrameCryptor.swift`, default per 1:1 dalla riscrittura; il decoratore custom resta come fallback). Desktop resta sul dialetto JS custom via insertable-streams (`LiveKitFrameCryptor.ts:337-376` — LiveKit qui è il nome della dipendenza SDK per le group call, non altro) che ora DICHIARA AES-256-GCM/HKDF byte-matching con la libreria nativa di Android — ma l'interop live Android↔desktop non è mai stato ri-verificato dal finding "BROKEN" del 2026-05-12, e Android fail-chiude il video contro un mismatch. Se la derivazione JS devia di un byte, il video misto è nero OGGI senza fallback.
Lavoro: (1) KAT (known-answer test) che pinna i byte della derivazione desktop contro vettori generati dalla libreria nativa Android — il KAT entra nel CI desktop e diventa il guardiano permanente del dialetto; (2) chiamata video live Android↔desktop; (3) stessa chiamata live iOS↔Android (dovrebbe interoperare nativamente, merita comunque la verifica). Se il KAT fallisce, la Fase D contiene la decisione di convergenza.

Test live di chiusura Fase A: giro completo a 4 endpoint (A36 + S26 + iPhone + desktop) con correlazione `qa-logs <short8>`: (a) chiamata mista con blip WS forzato mid-call (toggle aereo 5s) — la chiamata DEVE sopravvivere via cancellazione del teardown di grazia, e i log server devono mostrare l'asserzione accettata; (b) blip oltre il ceiling — il client DEVE ricevere e onorare il call_hangup post-authenticate; (c) offerta ribufferizzata (callee offline al dial, riconnessione dopo la rinuncia del caller) — nessun phantom ring; (d) chiamata forzata su relay con la flotta multi-gruppo attiva — parsing pulito su entrambe; (e) le due chiamate video del punto A7.

### Fase B — Robustezza di setup e fine chiamata

Dipende da A5 (mappa dei reason) e A2 (asserzione). È la fase che elimina le code di fallimento visibili all'utente: chiamate che non partono su link instabili, chiamate che non muoiono quando dovrebbero.

B1 — Retry di setup (W-SETUPRETRY).
Android ritrasmette e dedupa; il dedup RX esiste già su iOS e desktop, quindi RICEVERE retry è già sicuro — mancano le ritrasmissioni TX. Un solo call_answer/call_accepted perso oggi fallisce l'intero setup misto.
- iOS: il retry 5s del PQC OFFER esiste (`QAudionCallIntegration.swift:4180`); i JSON call_offer/answer/accepted restano single-shot in `BCryptoCallingApiImpl` — estendere la stessa scala di retry, con dedup lato proprio.
- Desktop: `CallController.startCall:2595-2654` — bundle OFFER single-shot, il responder aspetta 25s passivi. Stessa scala.
- Nota wire: il PQC OFFER opaco resta emesso esattamente una volta per contratto (lo store+replay offline del server è load-bearing, i ricevitori sono idempotenti — duplicato OFFER rigioca l'ACCEPT cached); il retry qui riguarda gli envelope JSON, non il bundle PQC.

B2 — Tiebreak di glare (W-GLARE).
La regola deve essere bit-identica su tutte le piattaforme (il tiebreak sul callId; il perdente adotta la chiamata superstite) — oggi Android la esegue mentre iOS/desktop busy-rejectano, e la gamba superstite riceve il busy: entrambe le chiamate possono morire. Copiare la regola esatta da Android (CallController Android, sezione glare), non reinterpretarla.
- iOS: path incoming-while-dialing nell'handler call_incoming di AppState (~L4643).
- Desktop: `CallController.ts:5179-5201`.

B3 — Eco e park dell'hangup (W-HANGUPECHO + W-HANGUPPARK).
Invariante: un hangup emesso mentre il WS è giù NON va perso — park fino a 45s (sotto il ceiling 60s del server) con resend su awaitSendReady; e un hangup ricevuto su canale DC/opaco va ECHOATO al server come `call_hangup {reason:"peer-acknowledged"}` per chiudere i libri contabili (altrimenti il server tiene la chiamata tracciata fino alla grazia).
- iOS: `AppState.swift:13821-13870` endCall — invia call_hangup ma senza park/resend né echo.
- Desktop: `CallController.ts:3070-3128` (fire-and-forget) + branch di ricezione :4846-4854 (nessun echo).
- Nota: il peer che riceve un `peer-acknowledged` tardivo non alza UI (già coperto in A5).

B4 — Piggyback opaco dell'hangup, lato EMIT su iOS (hangup-opaque-piggyback).
Il prefisso `<callId>|HANGUP:<reason>` sul canale opaque_message esiste perché bcrypto-lite in certi path scarta silenziosamente l'envelope call_hangup: iOS oggi lo parsa in ingresso ma lo droppa per design e non lo emette mai — quindi l'hangup iOS può svanire esattamente negli scenari per cui il prefisso è nato. Minimo indispensabile: il lato EMIT. Desktop è già byte-compatibile nei due versi (`CallController.ts:3070-3128`).
- iOS: `AndroidHandshakeBundle.swift:313,360,444` — aggiungere l'emissione dual-send accanto all'envelope.
- Contratto opaque completo per chi tocca questi file: il client manda `{recipient_id, data}`; il server rilancia `{sender_id, data}` verbatim e, senza socket fresco, lo storicizza come MsgType `"opaque"` dentro `msg_pending_sync` — ogni client DEVE demuxare per msg_type (`opaque` vs `msg_send`): i wire opachi sono stringhe piane `<callId>|<payload>`, NON base64, NON cifrate con la chiave chat — darli in pasto al decryptor chat ha causato l'outage inbound del 2026-08-01. Prefissi registrati dopo `<callId>|`: bundle JSON handshake `{..."kind":"OFFER"|"ACCEPT"...}` (unica shape che inizia con `{`), `HANGUP:<reason>`, `CAPS:<w>x<h>@<fps>:<bitrateBps>`, `VNACK:<frameId>:<i,i,...>`, `PLP:<int percent>`, `VBWCAP:<int bps>`, `SCREEN_SHARE:start|stop`, `VOICE_KEY:`, `OWNER_CONT:`, `EARBUDPDU`. Il demux esiste su Android (PendingSyncDemux) e iOS (W328); il desktop va verificato prima di aggiungere nuovi prefissi.

B5 — Terzo canale di hangup in-band (dc-hangup-v1).
Mux byte 0x03 sul DataChannel sealed, capability-gated (`dc-hangup-v1`), best-effort. Quando il WS del peer è in riconnessione al momento dell'hangup, questo è il canale che arriva.
- iOS: `WireRelayFrameCodec`/mux in `CallService.swift` (grep dc-hangup = 0 oggi).
- Desktop: `DataChannelMediaTransport` (`MediaTransport.ts:234` — il DC porta solo 0x01 audio). AVVISO DI PORTING già inventariato: desktop usa già '0x03' come dialetto opaco QUAD DC_SDP_OFFER a un ALTRO layer — verificare che non ci sia collisione di mux-byte quando si aggiunge il mux di controllo; se collide, la risoluzione va concordata sul wire (non riassegnare unilateralmente il byte Android).
- Compatibilità mista: gated dal tag, quindi l'assenza è sicura; senza tag il canale semplicemente non esiste sulla chiamata.

B6 — Watchdog media-dead (W-MEDIADEAD, 90s).
Invariante: un peer morto con tutti i canali di hangup persi non lascia mai una zombie call indefinita. CAVEAT DI PORTING ereditato da Android, non negoziabile: la liveness deve venire da frame realmente DECODIFICATI, mai da un tap che include il concealment (il concealment produce "audio" per sempre da un peer morto).
- iOS: nessun watchdog audio oggi (solo WS ping heal + VIDEODIAG video-only) — accanto a `VideoStallSelfHeal`/watchdog di AppState.
- Desktop: grep backstop = 0 in calling/ — in `CallMediaSession` o watchdog per-chiamata in `Call.svelte` accanto a videoStallPoll; i commenti del file documentano già da soli il failure mode risultante.

B7 — call_missed (W-MISSEDEVT).
Server completo (envelope live + store durabile). Desktop non ha NESSUN handling: le chiamate perse con desktop offline >60s non emergono mai — perdita silenziosa visibile oggi, il chiamante Android assume che il callee sia stato notificato.
- Desktop: handler del message-type + layer notifiche.
- iOS: l'envelope live è gestito (`AppState.swift:5135-5147`); da verificare il consumo durabile dal message-store al cold sync.

B8 — Item minori di coda fase: tombstone TTL per chiamate finite (W-DEADCALLACK, residuo a bassa urgenza dato il backstop server); audit tassonomia reason nelle cronologie (W-ENDREASONS — mappare anche i reason server `peer_disconnected` e `recall`); fasi/segnali di chiamata UI (W-CALLPHASES+W-CALLCUES) — ORDINE UTENTE DA MANTENERE: il suono di riconnessione fu rimosso esplicitamente, solo indicatore visivo (pill), qualunque porting conserva la decisione.

Test live di chiusura Fase B: (a) crash forzato dell'app peer mid-call → il watchdog chiude entro 90s su tutte le piattaforme; (b) hangup emesso durante blip WS → il peer chiude via DC-hangup o via park/resend, mai via watchdog; (c) dial reciproco simultaneo ripetuto N volte (script) → una e una sola chiamata sopravvive sempre; (d) desktop offline 5 minuti, chiamata persa → notifica al ritorno; (e) correlazione qa-logs su ogni scenario, verificando che i libri server si chiudano col reason giusto.

### Fase C — Path audio

Dipende da B4 (prefissi opachi funzionanti). Contiene la decisione di policy più pesante del piano.

C1 — Decodifica FEC (W-FECDECODE).
Android paga ridondanza FEC in-band su OGNI chiamata mista che il ricevitore non decodifica mai: banda pura senza beneficio, ogni frame perso diventa concealment invece di ricostruzione esatta dal frame N+1.
- iOS: `OpusCodec.swift:325` — `decode_fec=0` documentato (W-IOSFECFLAG); implementare il recovery reale del gap.
- Desktop: `AudioCodec.ts:426-459` — solo PLC repeat-fade; aggiungere il path decode_fec.

C2 — Loop di feedback packet-loss (W-PLPFEEDBACK).
Prefisso opaco `PLP:<int percent>`: emit del proprio loss misurato + consume di quello del peer → knob expected-loss dell'encoder Opus. Oggi il loop è aperto in entrambe le direzioni (le emissioni Android vengono droppate come prefisso ignoto — sicuro ma inutile).
- iOS: handler prefissi in `AndroidHandshakeBundle`/`CallService` + knob encoder.
- Desktop: handler opachi in `CallController.ts` + knob plp in `AudioCodec`.
- Compatibilità mista: il prefisso ignoto si droppa in sicurezza — deploy indipendente per piattaforma, il beneficio arriva appena entrambi i lati lo parlano.

C3 — Invarianti jitter (W-JBADAPT + W-JBSTRETCH + W-JITTERCAP).
Invariante scritto, da testare per piattaforma: "il ritardo di playout accumulato viene recuperato senza drop udibili, e il ritardo totale è limitato (cap 600 ms)". Meccanismo libero:
- iOS: `PlayoutJitterBuffer.swift` è un porting verbatim dei tier Android (80/140/160/300 ms, cap 600) — il cap c'è (W-JITTERCAP presente); il catch-up però è silence-skip/drop, udibile a 60 ms/frame: serve time-stretch (SOLA o equivalente; grep SOLA = 0 oggi), e il target adattivo va verificato, non assunto.
- Desktop: `SealedAudioPipeline.ts:688` schedulePlayback — cuscino fisso 60 ms, i commenti dichiarano apertamente che non c'è né jitter buffer né concealer al playout; gli slip sono contati ma non limitati (righe 766-778) — è il bug Android pre-068ec6d32, vivo oggi: i peer Android finiscono a parlare con un desktop che ascolta secondi nel passato. Qui il buffer va costruito, non adattato.
- Nota di coordinamento: il lavoro sul time-stretch è già avviato in una sessione dedicata — questa fase ne integra l'esito, non lo duplica.

C4 — Decisione audio-srtp-v1 (+ W-SRTPFALLBACK, W-SRTPPTIME contingenti).
Stato reale, senza edulcorare: su desktop l'assenza dell'audio SRTP è una POSIZIONE DI SICUREZZA deliberata (W574d: un track audio SRTP giudicato classico/relay-MITM-abile fuori dal SAS; `srtpDirKeyV1` è pubblicizzato solo per rilevare downgrade), non un'omissione. Su iOS è un blocker tecnico: la build WebRTC in uso non espone RTCFrameEncryptor, e iOS deliberatamente non costruisce alcun track m=audio. Ogni chiamata mista oggi viaggia quindi sul path audio sealed DC/WS-relay: niente NetEQ, niente NACK/RTX, latenza e gestione perdita peggiori del comportamento standard di settore che Android-Android già ottiene.
Il piano NON prescrive il porting: prescrive la RISOLUZIONE ESPLICITA della questione di policy, con tre esiti possibili da registrare in docs/: (a) il path sealed resta il canale audio cross-platform permanente — allora si codifica la scelta, si smette di considerarlo un gap, e si investe sul renderlo buono (C3 diventa ancora più centrale); (b) si porta SRTP audio — allora il bundle è indivisibile day-one: `audio-srtp-v1` + W-SRTPFALLBACK (o le chiamate SRTP muoiono sugli outage ICE che Android sopravvive) + W-SRTPPTIME (munging ptime 60, o si regredisce a 3x packet rate contro il pin Android); su iOS il prerequisito è risolvere il gap RTCFrameEncryptor (fork/upgrade della build WebRTC — sforzo NON stimato, incognita dichiarata); (c) si rinvia con non-advertise esplicito e data di revisione. Fino alla decisione: sicuro per costruzione, l'intersezione non scatta mai.

C5 — dc-mux-v1 su iOS: non è un chore di parità.
Il codice è completo (W-DCMUX, DC-first per-frame con fallback relay) ma `dcMuxAdvertiseEnabled=false` per decisione esplicita dell'utente: la condizione (b) del kill-switch non è soddisfatta (acceso il 2026-08-21 per finestra di test, rispento il 2026-08-22). Costo attuale: l'audio iOS↔tutti resta su WS relay end-to-end (carico server + latenza contro DC). Azione nel piano: portare la condizione (b) a risoluzione documentata, POI flippare — mai il contrario.

C6 — Residui aprof-60x256: la negoziazione è completa ovunque (iOS 1.0.959 con fix del floor di playout; desktop default incondizionato dal 2026-08-14 — l'inventario che lo dava "ancora spento" era stale). Restano: copertura live del playout scheduling 60 ms desktop, e il test per-piattaforma dell'invariante "il consumer audio non si affama mai" (il budget di concealment è in TEMPO: a 60 ms una perdita costa 3x).

Test live di chiusura Fase C: chiamate miste su link degradato controllato (network conditioner: 5%/15% loss, jitter 80 ms) per ogni coppia di piattaforme; verifica: loop PLP chiuso nei log (emissione e knob applicato su entrambi i lati), recovery FEC contato contro il concealment, ritardo di playout limitato e recuperato senza artefatti udibili (registrazione e ascolto, non solo metriche), zero slip cumulativo su desktop su una chiamata di 10 minuti.

### Fase D — Recovery video ed E2EE: osservabilità e sweep di sicurezza

Dipende da A7 (baseline sframe verificata) e B4 (prefissi opachi).

D1 — Recovery rapido da decrypt-fail (W-KFFAST).
Meccanismo Android: il segnale immediato del cryptor su frame non decifrabile → richiesta keyframe rate-limited, invece di aspettare il watchdog di stallo multi-secondo. Nota tassonomica per chi cerca nei sorgenti: W-NATIVEPLI non esiste come marker — la soppressione PLI + W-KFFAST È il meccanismo.
- iOS: `NativeVideoFrameCryptor` ora ESISTE con il meccanismo di state-callback disponibile (l'inventario Android che lo negava è stale) — il wiring decrypt-fail → richiesta keyframe rate-limited è diretto, in `QAudionWebRtcCallController`.
- Desktop: oggi i decrypt-fail droppano e il watchdog di stallo alla fine chiede il keyframe (secondi); l'hook diretto vive nella receiver transform di `LiveKitRtpCryptorAdapter.ts:422`.

D2 — Follow-up sframe: il KAT di Fase A diventa permanente in CI; decisione di lungo periodo da registrare: convergere il desktop sul cryptor nativo (architettura allineata alle altre due piattaforme) o mantenere ufficialmente il dialetto JS pinnato dal KAT. Nessuna delle due è gratis; l'importante è che il limbo attuale ("dichiara byte-matching, mai verificato live") finisca in Fase A e non ritorni.

D3 — Cap video receiver-driven (W-BWCAP, prefisso `VBWCAP:<int bps>`): emit della decisione di ladder del proprio downlink + consume con clamp del sender. Entrambe le piattaforme, entrambe le direzioni. iOS: handler opachi + clamp encoder; desktop: handler opachi + clamp sul ladder del sender. Prefisso ignoto = drop sicuro, deploy indipendente.

D4 — Clamp di bitrate su demozione di rotta (W-ROUTECLAMP): dopo Direct→Relay mid-call i sender iOS/desktop oggi tengono bitrate da tier direct e sparano sulla gamba TURN. Note di porting da Android: observer event-driven (non polling), e la lezione classe-ANR — mai lavoro pesante sul signaling thread. iOS: observer PC + policy bitrate (`QAudionWebRtcCallController.swift:1913-1966` oggi mappa solo stati); desktop: layer stats/ladder di `PeerConnectionManager`.

D5 — Backpressure CPU (W-BACKPRESSURE): `qualityLimitationReason` dal poll stats → step-down del ladder, su entrambe.

D6 — Audit (non gap confermati, onestà sul non-verificato): W-ADAPTFORMAT — verificare che i ladder di entrambe rescalino l'output (analogo di adaptOutputFormat) invece di riavviare la capture per gradino; W-SCREENPROFILE — profilo screenshare fps-over-resolution senza forzare 16:9 (il lato wire di SCREEN_SHARE_PROTOCOL.md è già condiviso). Esito atteso: o "verificato conforme" o un item di lavoro nuovo — non lasciare UNAUDITED.

D7 — Sweep di sicurezza sul logging di materiale chiave (lezione W-AES256DIAG).
Contesto: su Android una .so -diag3 spedì hex di chiave raw a logcat a livello ERROR in produzione. La stessa classe di leak è NON AUDITATA sugli altri due path E2EE. Questo è un item di sicurezza, non di interop, e va eseguito come sweep dedicato, non come task in mezzo a un porting: (1) iOS — sweep del logging dell'engine e del fork WebRTC per qualunque materiale chiave o chiave derivata, a TUTTI i livelli di log che raggiungono file o crash report; (2) desktop — stesso sweep su SFrameCodec/cryptor JS + logging Electron. Meta-lezione da portare nelle regole: le sostituzioni di dipendenze devono essere root-scoped (il leak Android entrò da una sostituzione non root-scoped).

Test live di chiusura Fase D: rekey forzato mid-call e burst di perdita con misura del tempo di recovery video (target: paragonabile ad Android, non "alla fine si riprende"); demozione di rotta forzata con verifica del clamp nei log; screenshare di testo in portrait letto dal ricevitore Android; sweep D7 completato con esito scritto.

### Fase E — Igiene di trasporto e recovery ICE

L'ultima fase contiene sia gli item piccoli di igiene sia la roccia più grossa del piano (la macchina di ICE restart), messa qui perché non blocca nessun'altra fase.

E1 — Cap delle code WS (W-WSQUEUECAP).
Il failure mode è già documentato: relay WS su link in stallo → 50fps di frame accumulati in memoria di processo → flush di secondi di audio STALE al peer al recovery, più possibile starvation del socket di signaling condiviso. Android cappa a 16KB testo / 64KB binario con drop solo-media. AVVISO ESPLICITO: verificare la semantica di buffering di CIASCUN client WS prima di copiare i numeri — le semantiche differiscono.
- Desktop (il caso grave): `WebSocketMediaTransport.send` (`MediaTransport.ts:685`) + `BCryptoSocket.sendBinaryRelay` (:698-733) — grep bufferedAmount/sendQueue = 0, la libreria ws bufferizza senza limite. Bound via bufferedAmount con drop solo-media.
- iOS: nessun bound outbound lato app (URLSession bufferizza nell'OS — semantica diversa dal kill 16MiB del client Android); la coda inbound pending-binary È già limitata; i media send hanno già i kick di riconnessione rate-limited (W574c). Verificare e documentare la semantica OS, aggiungere bound applicativo se serve.

E2 — Il trio anti-zombie-pool HTTP (http2-zombie-pool + W-INFLIGHTCANCEL).
Regola generale da portare, meccanismo libero: NIENTE di illimitato sul hot path del handshake. Il trio: (1) evict del pool al cambio rete, (2) keepalive ping (Android: ping HTTP/2 10s), (3) identity resolve offline-aware e bounded. Più il quarto: cancel delle richieste in-flight al cambio path (W-INFLIGHTCANCEL).
- iOS: config URLSession + path identity-resolve — il meccanismo differirà da quello Android, l'invariante no.
- Desktop: `BCryptoApi.ts` (fetch globale Chromium) — oggi solo AbortController per-request (:1748) e una negative cache 404 (`Application.ts:516`); nessun evict, nessun ping, nessun offline-awareness. Anche qui il meccanismo sarà diverso (Chromium gestisce il pool), ma nulla oggi implementa o VERIFICA il trio — se Chromium lo fa gratis, va dimostrato con un test di handoff, non assunto (lezione AudioTrack, di nuovo).

E3 — Macchina di ICE restart (W-SILENTPATHDEATH, il macigno).
iOS non ha NESSUN recovery ICE di alcun tipo — grep restartIce = 0; NWPathMonitor oggi regola solo il timing dei ping WS. Un handoff WiFi→cellulare mid-call su iPhone non ha alcun path di ripristino ICE: si regge su riconnessione WS + fallback relay per-frame. Il desktop è nello stesso stato. Il modello Android da portare come invariante: regather con timer armato che copre anche il NAT rebind SENZA evento OS (il caso silente che dà il nome all'item).
In bundle indivisibile con la macchina, quando arriva: W-OFFERGLARE 1:1 (initiator-wins, responder con rollback inline — la parte upgrade-glare è già fatta su entrambe: `UpgradeFlowDecisions.swift:79-103`, `upgradeStateMachine.ts` decideGlare) inclusa la mina già pagata su Android: MAI eseguire il rollback sotto il lock di signaling (l'analogo per-piattaforma del Mutex non rientrante va identificato prima di scrivere il codice); e W-RESTARTOFFERPARK (park 45s della restart-offer sotto il ceiling 60s del server, o un outage WS durante l'handoff incaglia il recovery per sempre).
- iOS: `QAudionWebRtcCallController` (restart) + `QAudionCallIntegration` (offer flow).
- Desktop: `CallController` + `PeerConnectionManager`.
- Compatibilità mista: finché una piattaforma non ha la macchina, il glare di restart non può accadere verso di lei (solo Android inizia restart-offer) — l'ordine di landing interno alla fase è libero.

E4 — Rilevamento credenziali TURN guaste (W-TURNSUSPECT): desktop non ha nulla; iOS ha il forceRefresh dopo auth-failure (`RelayCredentialsProvider`:1-128) ma manca il trigger sul conteggio zero-relay-candidate. Senza, credenziali scadute degradano silenziosamente ogni chiamata relay-dipendente fino a restart o TTL.

E5 — Minori: correlazione RTT sui pong desktop (W-PINGRTT — il watchdog di liveness esiste già, `BCryptoSocket.ts:345-378`); verifica W-OFFLINEPARK che nessuna delle due bruci retry in modalità aereo (entrambi i design di backoff sono sani, il parking esplicito su transport==NONE non è evidenziato).

E6 — Prerequisito di osservabilità (da W-DELAYSPLIT+W-RELAYID, non-port): prima di accettare ticket di latenza su iOS/desktop, dotarli di strumentazione equivalente allo split del ritardo Android — altrimenti ogni report resta indebuggabile. Non è interop; è la condizione per chiudere il cerchio diagnostico delle fasi C ed E.

Test live di chiusura Fase E: (a) handoff WiFi→cellulare mid-call su iPhone e su desktop (hotspot) — la chiamata sopravvive via ICE restart, misurando il gap audio; (b) NAT rebind simulato senza evento OS (router reboot) — il timer regather recupera; (c) link in stallo 10s su chiamata relay WS desktop — al recovery NIENTE flush di audio stale (ascolto + log); (d) credenziali TURN forzate a scadenza — rilevamento e refresh senza intervento utente; (e) handoff con richiesta identity in volo — nessun timeout pieno. Tutto correlato via qa-logs.

---

## 4. Regole trasversali

Disciplina di capability negotiation. Mai assumere, sempre intersecare: una feature wire nuova esiste su una chiamata solo se ENTRAMBI i peer l'hanno pubblicizzata su quell'offer/answer. Il tag entra nel registro della piattaforma solo insieme all'implementazione verificata, mai prima. Ogni kill-switch nasce spento (ships false) e si accende per decisione, non per default di build. Tag sconosciuti si ignorano nell'intersezione, mai rifiutati. Il grant bin_relay è un'eco per-socket: mai latchato attraverso riconnessioni. Il server resta cieco per contratto: nessuna PR server deve mai introdurre una costante per un tag di capability — i test di passthrough sono il guardiano, non toccarli per "semplificare".

Audit del materiale chiave nei log. La lezione W-AES256DIAG è una regola permanente, non un item una tantum: ogni modifica ai path E2EE su qualunque piattaforma include la verifica che nessun materiale chiave, chiave derivata o parametro sensibile raggiunga log, file o crash report a nessun livello. Le sostituzioni di dipendenze si fanno root-scoped, sempre. Lo sweep dedicato di Fase D7 stabilisce la baseline; da lì in poi vale il presidio in review.

Disciplina di commit clean-room. Con sessioni parallele su tre repo: commit sempre con path espliciti (`git commit -- <paths>`) — l'indice è condiviso e il lavoro staged di un'altra sessione finisce nel tuo commit altrimenti; i subagent non stageano mai. Gate CI locale prima di ogni push; fix correlati in batch nel commit, non frammentati. Nessun nome di prodotto concorrente in codice, commit o docs — dove serve un riferimento, "comportamento standard di settore"; l'unica eccezione ammessa è il nome della dipendenza SDK per le group call dove compare come nome tecnico.

Grafo del codice sempre allineato. Dopo ogni commit su qualunque dei tre repo: `graphify update <root>` (l'hook post-commit lo fa da sé; a metà sessione con modifiche non committate, lancio manuale se serve precisione). Ogni sessione di porting APRE con `graphify query/explain` sul repo target prima di toccare i file — i numeri di riga di questo documento invecchiano, il grafo no.

Invarianti scritti e testati per piattaforma. Ogni item di tipo invariante produce, oltre al codice: (1) l'invariante come frase testabile nel doc di piattaforma, (2) un test che lo verifica su QUELLA piattaforma, anche quando l'API sembra garantirlo gratis. Nessun "su questa piattaforma non serve perché il framework lo fa" senza il test che lo dimostra.

Verifica sull'artefatto spedito. Ogni fase si chiude col test live sulla build reale installata (TestFlight/installer), non sul sorgente né sul simulatore soltanto: flag spenti, log che non partono, transport mancanti sono invisibili dal codice — è già successo tre volte in un giorno.

---

## 5. Stima e sequenza consigliata delle sessioni

Premessa onesta: le stime sotto sono in sessioni di lavoro (mezza-una giornata effettiva l'una), non in giorni di calendario, e tre incognite possono muoverle sensibilmente: (1) l'esito del KAT sframe desktop — se i byte non combaciano, la Fase D2 diventa un lavoro di convergenza non stimato qui; (2) la decisione audio-srtp — l'opzione (b) su iOS implica un intervento sulla build WebRTC di sforzo ignoto; (3) i quattro item UNAUDITED — ognuno può risolversi in "conforme, zero lavoro" o in un item nuovo.

| Fase | Binario iOS | Binario desktop | Sessioni test live | Note |
|---|---|---|---|---|
| A | 2 | 2 | 1-2 | Item piccoli, verifica pesante; A7 (sframe) può allungare |
| B | 3 | 3 | 1-2 | B5 desktop: risolvere prima la collisione 0x03 |
| C | 3-4 | 4-5 | 2 | Desktop costruisce il jitter buffer da zero; C4 è una decisione, non codice — va presa PRIMA di iniziare la fase |
| D | 2 | 2-3 | 1 | Più 1 sessione dedicata allo sweep D7 (non comprimibile in altre) |
| E | 4-5 | 4-5 | 2 | E3 (ICE restart) è ~3 sessioni da solo per binario |

Totale indicativo: 14-16 sessioni per binario iOS, 15-18 per binario desktop, 7-9 sessioni di test live congiunte. Con i due binari realmente in parallelo (sessioni/agent separati per repo, disciplina clean-room), il tempo di calendario è quello del binario più lento più i punti di sincronizzazione (i test live di fine fase richiedono entrambi i binari alla stessa fase).

Sequenza consigliata:

1. Subito, prima di qualunque altra cosa: A2 (`active_call_id`) su entrambe — è il P0 a rapporto valore/costo più alto dell'intero piano (un campo + un handler, elimina la morte delle chiamate miste a ogni blip) — e A7 (verifica sframe live + KAT), perché finché non è fatta non sappiamo se il video misto Android↔desktop funziona oggi.
2. Resto della Fase A, poi B completa: a valle di A+B le chiamate miste partono e finiscono in modo affidabile — è il plateau di qualità percepita più importante.
3. Le due decisioni di policy (C4 audio-srtp, C5 dc-mux iOS) vanno portate all'utente e risolte durante la Fase B, così la Fase C parte senza ambiguità di scope.
4. C e D possono sovrapporsi tra loro (audio e video toccano file diversi); D7 (sweep sicurezza) si pianifica come sessione a sé.
5. E per ultima, con E3 (ICE restart) come coda lunga; E1 (queue cap desktop) però è un P1 che conviene anticipare dentro la prima sessione E disponibile — è piccolo e il failure mode (flush di audio stale) è brutto.

Ogni sessione di porting segue lo stesso rito: graphify sul repo target, lettura dei file reali citati (i numeri di riga di questo doc sono lo stato al 2026-08-22 — verificarli, non fidarsi), implementazione, test dell'invariante, commit clean-room con path espliciti, graphify update, e al confine di fase il test live correlato via qa-logs prima di dichiarare la fase chiusa.