# DECISIONS — append-only

> Decisioni architetturali/di processo con il **perché**. Mai cancellare; superare con una nuova decisione datata che cita la precedente.

---

## 2026-04-20 / D-01 — Isolated feature branch, not main
Parity effort ships on `feature/ios-android-parity` (off `main` @ 4516e01).
**Why:** `main` must stay TestFlight-releasable any day. A 13-phase multi-week effort can't contaminate it.
**How to apply:** Never commit parity work directly to `main`. Merge only when final code review approves and a tagged release is planned.

## 2026-04-20 / D-02 — Tag convention `v1.0.24-phN`
Per-phase verification tag uses suffix `-ph<N>`. Clean tag `v1.0.24` reserved for final release.
**Why:** `v1.0.23` already exists. Suffixed tags let Codemagic validate each phase end-to-end without collision or premature "clean release" semantics.
**How to apply:** Push `v1.0.24-ph0`, `v1.0.24-ph1`, … after each phase's acceptance. Final merge to `main` → push `v1.0.24` (no suffix).

## 2026-04-20 / D-03 — Codemagic dorme fino al tag
Codemagic triggers only on `v*` tag push. Branch pushes don't fire any iOS workflow.
**Why:** Build minutes are finite; WIP commits shouldn't burn them. GitHub Actions `engine-tests.yml` still runs on every push (macOS Swift tests only, cheap).
**How to apply:** Agents never push feature-branch tags that match `v*` unless the phase is ready for Codemagic verification.

## 2026-04-20 / D-04 — Android as source-of-truth model
`D:\users\f10379a\DEV APP\BCRYPTO\Q-Audion Android New` is the reference implementation for protocols, wire format, HKDF parameters, NFC AID, QR layout, fingerprint formatting.
**Why:** Parity means byte-for-byte compatibility on the wire. Diverging would break iOS↔Android interop immediately.
**How to apply:** Before designing any iOS feature, `grep` the Android repo for the same flow. Where Swift stdlib differs from JVM (e.g. byte order, Base64 URL-safe padding), add a canonical helper + a KAT test against Android-generated vectors.

## 2026-04-20 / D-05 — Don't touch pre-existing BCrypto workstream
Working-tree files listed in `STATUS.md` belong to the USER's in-progress work and MUST NOT be staged or committed by parity agents.
**Why:** Those files (BCryptoWebSocketClient, BCryptoPresenceManager, etc.) are under active revision by the human. Silent inclusion would conflate two independent workstreams and muddy blame.
**How to apply:** Before `git add`, cross-check against the hygiene list. Prefer `git add <specific-paths>` over `git add -A` / `git add .`.

## 2026-04-20 / D-06 — Workflow = superpowers:subagent-driven-development
Fresh implementer subagent per task + two-stage review (spec → quality) + controller runs in same session.
**Why:** User explicitly chose mode "1". Maintains coordinator context integrity while isolating per-task state.
**How to apply:** Never batch implementers. Never skip either review. Dispatch code-quality review ONLY after spec review is ✅.

## 2026-04-20 / D-07 — Apple Developer Portal capability is a manual blocker
Task 0.1 (Push Notifications capability toggle in developer.apple.com) cannot be automated by any CI/agent; it's a human-in-the-loop step.
**Why:** Apple Developer Portal capabilities sit behind an interactive auth flow; `app-store-connect` CLI cannot modify capabilities on the identifier. Without the capability, the provisioning profile won't include `aps-environment` and signing will mismatch.
**How to apply:** Task 0.2 (entitlement) can land immediately (no signing cost yet — we don't tag). Task 0.4 (tag push → Codemagic) WAITS on Task 0.1 completion.

## 2026-04-20 / D-08 — onnxruntime remains pinned at 1.17.0
Locked in `QAudionEngine/Package.swift` as `exact: "1.17.0"`. Post-build Info.plist patch in `codemagic.yaml` stays.
**Why:** Documented in `CLAUDE.md` §4 — newer versions raise `MinimumOSVersion` to iOS 18, breaking iOS 16 target; 1.17 has `MinimumOSVersion=""` plist bug requiring the patch step. Nothing in parity effort should disturb either pin.
**How to apply:** If any Phase touches `Package.swift`, DO NOT upgrade onnxruntime. If any refactor makes the patch step look "redundant", leave it alone — it isn't.

## 2026-04-20 / D-09 — XcodeGen `sdk:` (not `framework:`) for system SDKs
`QAudionApp/project.yml` dependencies for CallKit/PushKit/CoreNFC/Contacts/etc. use `sdk: Foo.framework` form.
**Why:** `framework:` makes XcodeGen look for a local path → "No such file" error. Documented in `CLAUDE.md` §5.
**How to apply:** Task 0.3 (and any later framework additions) must use `sdk:` style.

## 2026-04-20 / D-11 — Remove `beta_groups: [Q-Audion testers]` from codemagic.yaml
After Phase 0 verification build (tag `v1.0.24-ph0`, build #40), the core build was green but post-processing "App Store distribution" failed: *"Failed to add build to 'Q-Audion testers' beta group. Cannot add internal group to a build."* `Q-Audion testers` is an **internal** group — ASC auto-assigns internal groups; the API rejects explicit add calls.
**Why this decision:** The build validates successfully and is automatically available to internal testers (us). Keeping `beta_groups` with an internal name causes every Codemagic run to report a false "finished with post-processing failed" even though the binary is live on TestFlight. This masks real failures in future runs.
**How to apply:** `beta_groups` in `codemagic.yaml` is now OMITTED. `submit_to_testflight: true` alone handles TestFlight distribution. Only re-add `beta_groups` if an EXTERNAL group is created in ASC (which then requires Apple beta review).
**Reference:** Commit with the fix is the first post-v1.0.24-ph0 Phase 0 cleanup. Supersedes implicit previous assumption that `beta_groups` could carry internal names.

## 2026-04-20 / D-10 — Knowledge base lives in `docs/progress/`
This folder is the canonical handoff surface between agents/sessions. 5 files (STATUS, TASK_LOG, DECISIONS, ANDROID_REFERENCE, CODEMAGIC_GUARD) + README (index).
**Why:** USER explicit directive: "aggiorna continuamente nella cartella il lavoro che fai con la memmory knolwdge, in mod che chiunque possa continuare il lavoro in corso".
**How to apply:** After every closed task: update `STATUS.md`, append row to `TASK_LOG.md`, consider `DECISIONS.md` if a non-obvious call was made. Commit with `docs(progress): <phase>/<task> <status>`.
