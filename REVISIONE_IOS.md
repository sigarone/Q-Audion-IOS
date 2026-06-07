# Report di Revisione Profonda del Codice iOS: Sicurezza, Interfaccia, Stabilità e Usabilità (Q-Audion)

Di seguito è riportato il resoconto completo basato sulla revisione approfondita dell'architettura e dell'implementazione di Q-Audion iOS.

---

## 1. Sicurezza (Security)

### 1.1 Robustezza Crittografica (AES-GCM & PQC)
- L'utilizzo di `CryptoKit` (`AES.GCM`) è eccellente in quanto sfrutta l'accelerazione hardware (AES-NI) ed è conforme a FIPS 140-3 sui dispositivi Apple.
- Le chiavi ML-KEM-1024 vengono derivate e passate correttamente.
- **Rischio identificato:** Le operazioni di decodifica nella chat e nei trasferimenti file possono operare sincronicamente su dispatch queues o persino nel thread principale (specialmente durante il ripristino o l'importazione di messaggi bulk). Questo apre potenziali vettori per attacchi di "Denial of Service" (DoS) locale se un attaccante invia messaggi malformati ad alta frequenza, o decodifica di grandi payload che causano freeze (l'app smette di rispondere o viene killata dal watchdog di iOS).

### 1.2 Gestione degli Errori Fatali (Crashes)
- Nel modulo `QAudionDatabase.swift` (riga 42), l'inizializzazione del database chiama `fatalError("Failed to initialize database: \(error)")` in caso di errore. Se il file SQLite è bloccato dal sistema operativo, o se un aggiornamento di schema fallisce, l'app va in *crash istantaneo* all'avvio.
  - **Raccomandazione:** Sostituire il `fatalError` con un fallback sicuro (es. chiusura sicura, spostamento del DB corrotto e creazione di uno nuovo, oppure avviso all'utente). L'uso in produzione di un `fatalError` in fase di avvio non è una pratica sicura per la continuità operativa.

---

## 2. Interfaccia e Usabilità (UX/UI)

### 2.1 Passaggio Audio/Video e Analisi Vocale (Il problema del Blocco UX)
L'utente ha segnalato un blocco dell'analisi vocale durante il passaggio tra la modalità "Solo Audio" a "Video" (e viceversa).
- **Causa identificata:** L'aggiornamento a video (`upgradeToVideo` e `performWebRtcVideoUpgrade` in `AppState.swift` e la gestione in `CallService.swift`) altera profondamente i transceivers WebRTC e lo stato del microfono locale (`setCamera`). Quando si passa da o verso il video, l'engine di fallback `WS-HEVC` viene smantellato o avviato, e questo processo ricarica l'audio.
- Il `CallService` possiede delle callback (`onDeepfakeScore`, `onTxWaveformUpdate`, `onRxWaveformUpdate`). Se durante l'upgrade video il transceiver audio viene sospeso temporaneamente e poi ripristinato, l'AVAudioEngine riavvia il tap, ma le closure della UX (in `InCallContainer` e `LiveInCallScreen`) perdono fluidità se eseguite sincronicamente oppure i frame audio non attraversano il classificatore.
  - **Raccomandazione:** Assicurarsi che le callback di aggiornamento del punteggio (Deepfake) siano ri-agganciate o che il tap PCM all'interno del `QAudionCallIntegration` non venga smontato durante la negoziazione WebRTC.

### 2.2 Reattività del Modello UI nel `LiveInCallScreen`
- Il modulo `LiveInCallScreen` fa forte affidamento su `TimelineView(.periodic(from: .now, by: 1))` per forzare un aggiornamento al secondo (usato per il timer del rekey). Sebbene parzialmente accettabile, in combinazione con i dati a 60fps (come le waveform di `txWaveformSamples`), questo rischia di sovraccaricare il rendering UI. Lo switch della videochiamata invia nuovi stream CVPixelBuffer sulla UI, portando la CPU/GPU al limite, inducendo così dei drop frame e l'apparente blocco dell'interfaccia di analisi vocale.

---

## 3. Stabilità e Prestazioni (Performance Drops)

### 3.1 Videochiamata (`VideoCallPipeline.swift` e WebRTC)
- Le prestazioni in videochiamata subiscono rallentamenti a causa di colli di bottiglia nel processo di codifica/decodifica:
  - Il metodo `captureOutput` elabora i CVPixelBuffer e li passa all'`HevcEncoder`. La codifica video tramite `VTCompressionSession` avviene in modo sincrono nella `captureQueue`. Se l'hardware ritarda, la coda di cattura blocca l'acquisizione dei nuovi frame e causa il riscaldamento del dispositivo e scatti video.
  - La decodifica in Rx aspetta l'estrazione sincrona dei payload e dei blocchi NAL, usando `VTDecompressionSessionDecodeFrame` con il flag `_EnableAsynchronousDecompression`. Tuttavia, la pipeline di arrivo nel `VideoCallPipeline` invoca funzioni di estrazione pesanti.
  - **Raccomandazione:** Spostare l'impacchettamento e l'elaborazione dei frame NAL in dispatch queues separate e non bloccare la `captureQueue` di Apple (che deve solo copiare e liberare i buffer).

### 3.2 Decodifica Messaggi Cifrati
- Il processing `AES-GCM` (`AeadCipher`) è velocissimo grazie all'accelerazione hardware, ma il collo di bottiglia sta nello spacchettamento e la decodifica base64 o JSON (`MessageRatchet` e `MessageCrypto`). Quando arrivano molti messaggi (es. sincronizzazione), deserializzare e decifrare sul thread principale blocca la navigazione della Chat e le animazioni SwiftUI.
  - **Raccomandazione:** Avvolgere il flusso di processing asincrono, inviando le decifrazioni pesanti (`Task.detached` o `DispatchQueue.global(qos: .userInitiated)`) e passando solo il risultato decifrato al MainActor per l'aggiornamento UI.

---

## 4. Conclusioni e Raccomandazioni Prossime
1. **Rimuovere `fatalError`** in `QAudionDatabase` per migliorare la resilienza.
2. **Ottimizzare la pipeline video** rimuovendo le operazioni intensive (serializzazione/frammentazione dei NAL) dal thread dell'AVCaptureSession in `VideoCallPipeline.swift`.
3. **Mantenere vivo l'Audio Tap** e il classificatore Deepfake (`VoiceAnalysisEngine`) isolandolo dalle interruzioni WebRTC durante la rinegoziazione audio/video (upgrade/downgrade).
4. **Spostare la Decrittazione massiva** dei messaggi offline dal thread principale a code background dedicate.