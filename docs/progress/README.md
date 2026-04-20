# Q-Audion iOS — Progress Knowledge Base

Questa cartella contiene lo **stato vivo** del lavoro di parità iOS ↔ Android.
Chiunque (umano o agente) può riprendere il lavoro leggendo questi 5 file.

## Come leggerla (ordine suggerito)

1. **[STATUS.md](STATUS.md)** — snapshot corrente: fase attiva, ultima task completata, prossima task, blocker aperti. *Sovrascritta a ogni task.*
2. **[TASK_LOG.md](TASK_LOG.md)** — log append-only per ogni task chiusa: SHA del commit, esito, note, timestamp.
3. **[DECISIONS.md](DECISIONS.md)** — decisioni architetturali e di processo con il perché. Append-only.
4. **[ANDROID_REFERENCE.md](ANDROID_REFERENCE.md)** — fatti estratti dal repo Android di riferimento (protocolli, costanti crypto, layout QR, AID NFC). Source of truth cached.
5. **[CODEMAGIC_GUARD.md](CODEMAGIC_GUARD.md)** — lista di invariant che la pipeline Codemagic si aspetta. Prima di cambiare `codemagic.yaml`, `project.yml`, entitlements o `Package.swift` — rileggere questo file.

## Il piano completo

Vedi `docs/superpowers/plans/2026-04-20-ios-android-parity.md`.
13 fasi, ~60 task bite-sized. Ogni task ha path esatti + snippet.

## Convenzioni

- **Branch di lavoro**: `feature/ios-android-parity` (off `main`).
- **Codemagic**: non si attiva su push di branch; solo su tag `v*`. Finché non taggo, il pipeline dorme.
- **Tag di verifica per fase**: `v1.0.24-ph<N>` (suffisso `-ph<N>`). Il tag di release finale sarà pulito `v1.0.24`.
- **Commit**: conventional prefix (`feat(ios):`, `fix(engine):`, `docs(progress):`, `build:`).
- **Nessun `fatalError` nel codice shippato.** Task bloccate vanno marcate **BLOCKED** in `STATUS.md`, non "finte-chiuse".
- **Le modifiche pre-esistenti del workstream BCrypto nel working tree** (modifiche dell'utente a `BCryptoBackendProvider.swift`, ecc.) NON vanno committate dagli agenti del parity effort.

## Come continuare il lavoro da zero contesto

1. `git fetch --all && git checkout feature/ios-android-parity`
2. Leggere `STATUS.md` → individuare "Next task"
3. Aprire il piano alla task indicata
4. Dispacciare un implementer subagent con solo il testo della task + il contesto di questo README
5. A task chiusa: aggiornare `STATUS.md`, appendere riga a `TASK_LOG.md`, eventualmente a `DECISIONS.md`
6. Commit dei progress files con messaggio `docs(progress): <phase>/<task> <status>`
