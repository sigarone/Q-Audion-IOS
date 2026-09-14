# Re-key media deafness (skew) — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the shipped Android fix (`qaudion-android-new`, `WIRE_SPEC.md`
§8.7 v1.2) to iOS: split `setKey`'s combined install+switch into two steps,
gate the sender switch on the peer's per-epoch `call_media_ready` or a
bounded 2s timeout.

**Design doc:** `docs/superpowers/specs/2026-09-04-rekey-media-deafness-skew.md`
— read it first, it documents the real current iOS architecture (verified
against actual code, not assumed) including the key difference from
Android (one shared `pqcSessionKeyEpoch`, not two independent counters)
and a specific trap to avoid (the eventual inbound-listener branch must
gate on the switch-gate being armed, not on `keyEpoch > 0` alone — Android
shipped a bug matching exactly this shape and it was only caught by a
final holistic review).

**Tech stack:** Swift, XCTest, existing `BCryptoWebSocketClient`/
`BCryptoCallingApiImpl` dictionary-based wire layer.

---

## File structure

- Modify `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoCallingApiImpl.swift` — `sendCallMediaReady` gains a `media` param.
- Modify `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoWebSocketClient.swift` — `onCallMediaReady` closure gains a `media` param, decode side reads the new dict key.
- New `QAudionEngine/Sources/QAudionEngine/Call/RekeySwitchGate.swift`.
- New `QAudionEngine/Tests/QAudionEngineTests/Call/RekeySwitchGateTests.swift`.
- Modify `QAudionEngine/Sources/QAudionEngine/WebRTC/NativeVideoFrameCryptor.swift` — split `setKey` into `installKey`/`switchSender`.
- Modify `QAudionEngine/Sources/QAudionEngine/WebRTC/NativeAudioFrameCryptor.swift` — same split.
- Modify `QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift` — wire the gates into the video/audio rekey call sites, add the timeout race.
- Modify `QAudionApp/AppState.swift` — extend `sendCallMediaReadyOnce`'s dedup, extend the `onCallMediaReady` consumer, thread the new `media` param through every real call site.

No server changes (already verified for Android: the Go relay decodes
`call_media_ready` into a generic map and forwards it whole).

---

### Task 1: Wire schema — additive `media` field

**Files:**
- Modify: `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoCallingApiImpl.swift`
- Modify: `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoWebSocketClient.swift`

- [ ] **Step 1: Read the real current `sendCallMediaReady` (~L740-759) and the `call_media_ready` handler (~L786-800) in full first** — confirm exact current signatures before editing; both were read on 2026-09-04 for the design doc but may have drifted.

- [ ] **Step 2: `sendCallMediaReady` gains a `media: String` parameter**:
```swift
public func sendCallMediaReady(
    callId: String,
    recipientId: String,
    mid: String,
    keyEpoch: Int,
    dir: String,
    media: String
) async throws {
    ws.send(type: "call_media_ready", data: [
        "call_id": callId,
        "recipient_id": recipientId,
        "mid": mid,
        "key_epoch": keyEpoch,
        "dir": dir,
        "media": media,
    ])
}
```
No default value — grep the whole repo for every real call site (`grep -rn "sendCallMediaReady(" --include="*.swift" .`) and update each one explicitly with `media: "video"` (matching today's only real use — this call has always been video-only until Task 4 adds an audio one). Do not silently change behavior for a call site you didn't find; if the grep surfaces more than the two sites the design doc names (`AppState.sendCallMediaReadyOnce`, `AppState.reannounceCallMediaReadyForSelfHeal`), read each one before deciding what `media` value it needs.

- [ ] **Step 3: `onCallMediaReady` closure type gains a trailing `media: String` param**, and the handler that fires it reads the new dict key with a default:
```swift
public var onCallMediaReady: ((_ callId: String, _ senderId: String, _ mid: String, _ keyEpoch: Int, _ dir: String, _ media: String) -> Void)?
```
```swift
registerHandler(type: "call_media_ready") { [weak self] _, data in
    guard let self = self,
          let callId = data["call_id"] as? String else { return }
    let senderId = (data["sender_id"] as? String)
        ?? (data["from"] as? String)
        ?? ""
    let mid = (data["mid"] as? String) ?? ""
    let keyEpoch = (data["key_epoch"] as? Int) ?? 0
    let dir = (data["dir"] as? String) ?? "recv"
    let media = (data["media"] as? String) ?? "video"
    self.onCallMediaReady?(callId, senderId, mid, keyEpoch, dir, media)
}
```
**Caution** (from the design doc): `data["media"]` is ALSO read a few lines above by the UNRELATED `call_upgrade_intent` handler, meaning "camera"/"screen" there — different message type, different meaning, not a real collision, but don't let it confuse a repo-wide grep.

- [ ] **Step 4: Update every assignment of `onCallMediaReady`** (grep `onCallMediaReady\s*=` across the repo — the design doc found one in `AppState.swift:5927`, discarding 3 of 5 params; it will need to become 6 params, and Task 4 is what actually makes it USE `keyEpoch`/`dir`/`media` meaningfully — for THIS task, just make it compile with the new signature, keeping its current behavior (log the event, nothing more) unchanged. Don't do Task 4's wiring here.

- [ ] **Step 5: Build.** Use whatever this repo's real build-verification path is — check `docs/handovers/` or `CLAUDE.md` for this repo for the established "no local compiler, verify via CI/Xcode" convention (matches this session's own earlier iOS work on the KeyExchangeRing feature) — if so, skip to self-review by reading the diff closely for type errors instead of assuming a build passes, and say so explicitly in your report.

- [ ] **Step 6: Commit.**
```bash
git add QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoCallingApiImpl.swift QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoWebSocketClient.swift QAudionApp/AppState.swift
git -c commit.gpgsign=false commit -m "feat(rekey): add media field to call_media_ready wire message"
```
(Only include `AppState.swift` if Step 4 actually required a change there.)

---

### Task 2: Port `RekeySwitchGate` to Swift

**Files:**
- New: `QAudionEngine/Sources/QAudionEngine/Call/RekeySwitchGate.swift`
- New: `QAudionEngine/Tests/QAudionEngineTests/Call/RekeySwitchGateTests.swift`

- [ ] **Step 1: Confirm `QAudionEngine/Sources/QAudionEngine/Call/` exists as a real directory** (it should — `ReKeyScheduler.swift` already lives there) before creating a new file in it.

- [ ] **Step 2: Write the test file first** (superpowers:test-driven-development), porting Android's 10 `RekeySwitchGateTest` cases to XCTest with the same intent:
```swift
import XCTest
@testable import QAudionEngine

final class RekeySwitchGateTests: XCTestCase {

    func testFirstAttemptForThePendingEpochSwitches() {
        let gate = RekeySwitchGate()
        gate.arm(1)
        XCTAssertTrue(gate.attemptSwitch(1))
    }

    func testSecondAttemptForTheSameEpochIsANoOp() {
        let gate = RekeySwitchGate()
        gate.arm(1)
        XCTAssertTrue(gate.attemptSwitch(1))
        XCTAssertFalse(gate.attemptSwitch(1))
    }

    func testReadyArrivingBeforeTimeoutWinsTimeoutBecomesANoOp() {
        let gate = RekeySwitchGate()
        gate.arm(2)
        XCTAssertTrue(gate.attemptSwitch(2))   // simulated "ready arrived"
        XCTAssertFalse(gate.attemptSwitch(2))  // simulated "timeout fired after"
    }

    func testTimeoutFiringBeforeReadyWinsReadyBecomesANoOp() {
        let gate = RekeySwitchGate()
        gate.arm(2)
        XCTAssertTrue(gate.attemptSwitch(2))   // simulated "timeout fired"
        XCTAssertFalse(gate.attemptSwitch(2))  // simulated "ready arrived after"
    }

    func testStaleEpochIsRejectedWithoutSwitching() {
        let gate = RekeySwitchGate()
        gate.arm(2)
        _ = gate.attemptSwitch(2)
        gate.arm(3)
        XCTAssertFalse(gate.attemptSwitch(2))  // a replayed/late ready for the OLD epoch
    }

    func testPrematureFutureEpochIsRejectedWithoutSwitching() {
        let gate = RekeySwitchGate()
        gate.arm(2)
        XCTAssertFalse(gate.attemptSwitch(3))  // a ready for an epoch we haven't armed yet
    }

    func testNoEpochIsSkippedAcrossAFullSequence() {
        let gate = RekeySwitchGate()
        gate.arm(1)
        XCTAssertTrue(gate.attemptSwitch(1))
        gate.arm(2)
        XCTAssertTrue(gate.attemptSwitch(2))
        gate.arm(3)
        XCTAssertTrue(gate.attemptSwitch(3))
    }

    func testCurrentPendingEpochReflectsTheMostRecentArm() {
        let gate = RekeySwitchGate()
        gate.arm(5)
        XCTAssertEqual(gate.currentPendingEpoch(), 5)
    }

    func testARejectedStaleEpochCallDoesNotBlockTheActuallyPendingEpochFromSwitching() {
        let gate = RekeySwitchGate()
        gate.arm(2)
        _ = gate.attemptSwitch(2)
        gate.arm(3)
        XCTAssertFalse(gate.attemptSwitch(2))  // rejected, must not mutate state
        XCTAssertTrue(gate.attemptSwitch(3))   // the real pending epoch still switches cleanly
    }

    func testARejectedPrematureEpochCallDoesNotBlockTheActuallyPendingEpochFromSwitching() {
        let gate = RekeySwitchGate()
        gate.arm(2)
        XCTAssertFalse(gate.attemptSwitch(3))  // rejected, must not mutate state
        XCTAssertTrue(gate.attemptSwitch(2))   // the real pending epoch still switches cleanly
    }
}
```

- [ ] **Step 3: Implement** — use the design doc's exact given code (already reproduced there in full): `RekeySwitchGate` as `NSLock`-guarded, `arm`/`currentPendingEpoch`/`attemptSwitch`, taking `Int32` to match `pqcSessionKeyEpoch`'s own type (not `Int`/`Int64` — check this against the REAL current type of `pqcSessionKeyEpoch` in `QAudionWebRtcCallController.swift` before committing to `Int32`, the design doc's own reading found it as `Int32` on 2026-09-04 but confirm it hasn't changed).

- [ ] **Step 4: Confirm the file doesn't reference `AppState`** (CLAUDE.md §16 constraint, same one `NativeVideoFrameCryptor.swift`'s own kdoc calls out) — it shouldn't need to, since it's a pure coordination primitive, but double-check before committing.

- [ ] **Step 5: Run tests** via whatever this repo's real test-running convention is (check for a `Package.swift`/`xcodebuild test` setup, or the same "no local compiler, CI/Xcode verifies" posture as Task 1 — if so, self-review the test logic by hand instead of claiming a run happened).

- [ ] **Step 6: Commit.**
```bash
git add QAudionEngine/Sources/QAudionEngine/Call/RekeySwitchGate.swift QAudionEngine/Tests/QAudionEngineTests/Call/RekeySwitchGateTests.swift
git -c commit.gpgsign=false commit -m "feat(rekey): add RekeySwitchGate, pure re-key sender-switch coordinator"
```

---

### Task 3: Split `setKey` into `installKey` + `switchSender`

**Files:**
- Modify: `QAudionEngine/Sources/QAudionEngine/WebRTC/NativeVideoFrameCryptor.swift`
- Modify: `QAudionEngine/Sources/QAudionEngine/WebRTC/NativeAudioFrameCryptor.swift`

- [ ] **Step 1: Read both files' real current `setKey` implementations in full first** (design doc quotes them verbatim from a 2026-09-04 read — confirm they still match).

- [ ] **Step 2: Split `NativeVideoFrameCryptor.setKey`**:
```swift
/// Install [key] into the decode ring at [slot] — this ALONE is what lets
/// this device decode a peer's frames already tagged with this slot/epoch
/// (the receiver is driven entirely by the on-wire key index, never by
/// this device's own sender state). Callable immediately upon deriving
/// the key; does NOT touch this device's own outbound frames. Returns
/// false if the key is the wrong size (nothing installed).
public func installKey(_ kVideo: Data, slot: Int32) -> Bool {
    guard kVideo.count == 32 else {
        print("[NativeVideoFrameCryptor] installKey ignored — key is \(kVideo.count) bytes, expected 32")
        return false
    }
    lock.lock(); defer { lock.unlock() }
    currentKeyIndex = Int(slot)
    keyProvider.setSharedKey(kVideo, with: slot)
    hasKey = true
    print("[NativeVideoFrameCryptor] key installed at slot \(slot)")
    return true
}

/// Switch THIS device's own outbound video frames to announce [slot] (the
/// slot [installKey] just installed). Call this only once the caller has
/// decided it is safe to switch (see RekeySwitchGate) — this function
/// itself has no timing/coordination logic.
public func switchSender(slot: Int32) {
    lock.lock(); defer { lock.unlock() }
    senderCryptor?.keyIndex = slot
    print("[NativeVideoFrameCryptor] sender switched to slot \(slot)")
}
```
Remove `setKey` entirely — no compatibility wrapper (Task 4 updates the two real call sites).

- [ ] **Step 3: Same split for `NativeAudioFrameCryptor.setKey` → `installKey`/`switchSender`**, mirroring exactly.

- [ ] **Step 4: Grep the whole repo for any OTHER caller of `.setKey(` on either cryptor type** (test files included) before assuming the two call sites the design doc names are the only ones:
```bash
cd "D:/users/f10379a/DEV APP/BCRYPTO/apps/qaudion-ios" && grep -rn "\.setKey(" --include="*.swift" .
```
Update any test call site found to use the new split functions.

- [ ] **Step 5: Self-review / build per this repo's real verification posture** — confirm the ONLY resulting compile errors (if a compiler is available) are in `QAudionWebRtcCallController.swift` referencing the now-removed `setKey` calls at the two known sites (~L3085, ~L3161, and the audio equivalent ~L2894-area) — nothing else. This is the expected, staged-migration break Task 4 fixes.

- [ ] **Step 6: Commit.**
```bash
git add QAudionEngine/Sources/QAudionEngine/WebRTC/NativeVideoFrameCryptor.swift QAudionEngine/Sources/QAudionEngine/WebRTC/NativeAudioFrameCryptor.swift
git -c commit.gpgsign=false commit -m "feat(rekey): split NativeVideoFrameCryptor/NativeAudioFrameCryptor setKey into install + switch"
```

---

### Task 4: Wire the gate into `QAudionWebRtcCallController` + `AppState`

**Files:**
- Modify: `QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift`
- Modify: `QAudionApp/AppState.swift`

- [ ] **Step 1: Read the real current state around `ensureVideoSealer`'s rekey branch (~L3082-3090), the audio install call site (~L2865-2905), `pqcSessionKeyEpoch`'s declaration and every reset site, and `AppState`'s `sendCallMediaReadyOnce`/`onCallMediaReady`/`reannounceCallMediaReadyForSelfHeal`/`mediaReadySentKeys` — this file is compile-broken from Task 3, confirm exactly what needs fixing before touching anything.**

- [ ] **Step 2: Add two `RekeySwitchGate` properties to `QAudionWebRtcCallController`**, near `pqcSessionKeyEpoch`:
```swift
let videoSwitchGate = RekeySwitchGate()
let audioSwitchGate = RekeySwitchGate()
```
Find every place `pqcSessionKeyEpoch` itself gets reset for a fresh call (if any — it may simply be re-set to a fresh value at call start rather than explicitly zeroed) and reset these two gates at the SAME site(s), to avoid the exact "stale gate state leaks into a new call" bug Android's implementer caught and fixed during Task 4 there (fresh `RekeySwitchGate()` instances or an explicit reset method — match whichever this file's own reset idiom already uses for sibling per-call state).

- [ ] **Step 3: Update the video rekey call site** (`ensureVideoSealer`, ~L3082-3090) to install immediately and defer the switch:
```swift
if case .native = videoSealer {
    let k = pqcSessionKeyProvider()
    if k.count == 32, let c = peerConnection?.nativeVideoCryptor {
        let epoch = pqcSessionKeyEpoch
        let slot = epoch % 16
        if c.installKey(k, slot: slot) {
            videoSwitchGate.arm(epoch)
            // send call_media_ready(media:"video", keyEpoch: epoch) here or
            // via whatever this controller's existing signaling-callback
            // pattern is (check how `onCallMediaReady`-adjacent outbound
            // sends already reach AppState/BCryptoCallingApiImpl from this
            // class — likely a closure property, not a direct import).
            // Race a 2s timeout against videoSwitchGate.attemptSwitch(epoch)
            // using this file's EXISTING 2s TX-hold timer idiom (~L1598,
            // 1741, 1768) rather than inventing a new one.
            print("video key fp=\(Self.shortFingerprint(k)) rekey=1")
        }
        peerConnection?.attachVideoSenderCryptor()  // idempotent — unrelated to the switch, keep as-is
    }
    return videoSealer
}
```
The exact mechanism for "send `call_media_ready` from inside
`QAudionWebRtcCallController`" and "race a 2s timeout" needs to match
this file's REAL existing idioms — it almost certainly does NOT call
`BCryptoCallingApiImpl`/`AppState` directly (CLAUDE.md §16 constraint,
same reason `RekeySwitchGate` itself must not touch `AppState`) — find
the existing closure-based callback pattern this class already uses to
ask the app layer to send a wire message (the TX-hold-timeout code this
same file already has for the ORIGINAL epoch-0 case is the right
reference implementation to copy the SHAPE of, not just the timeout
duration).

- [ ] **Step 4: Same treatment for the audio install call site** (~L2865-2905) — read it in full, adapt the same install→arm→announce→race-timeout shape for `audioSwitchGate`/`switchSender` on `NativeAudioFrameCryptor`.

- [ ] **Step 5: Extend `AppState`'s inbound `onCallMediaReady` handling.** Read the real current consumer(s) (`~L5927-5931`, `~L6840-6890`) in full. Add a new branch, gated on the relevant switch-gate being ARMED for the exact received epoch (NOT on `keyEpoch > 0` alone — this is the specific mistake Android's final review caught and fixed; read that review's finding, reproduced in the design doc, before writing this branch):
```swift
ws.onCallMediaReady = { [weak self] callId, senderId, mid, keyEpoch, dir, media in
    guard let self else { return }
    if keyEpoch > 0 {
        let gate = (media == "audio") ? self.videoController?.audioSwitchGate : self.videoController?.videoSwitchGate
        if let gate, gate.currentPendingEpoch() == Int32(keyEpoch) {
            if gate.attemptSwitch(Int32(keyEpoch)) {
                // switch the corresponding sender via whatever accessor
                // this file already uses to reach the live controller/cryptor
            }
            return
        }
        // Not a rekey-ready we're waiting on — fall through to existing handling.
    }
    // Existing handling — UNCHANGED below this line (releaseVideoTxHold, etc.)
    ...
}
```
Adapt variable names/access patterns to what's REALLY there (this is
illustrative of the required LOGIC shape, not literal code to paste) —
the load-bearing requirement is: reject any `keyEpoch > 0` event that
doesn't match an actually-armed gate, falling through to the pre-existing
epoch-0-style handling unchanged, exactly mirroring Android's final,
corrected shape.

- [ ] **Step 6: Self-review / build per this repo's real verification posture.**

- [ ] **Step 7: Commit.**
```bash
git add QAudionEngine/Sources/QAudionEngine/WebRTC/QAudionWebRtcCallController.swift QAudionApp/AppState.swift
git -c commit.gpgsign=false commit -m "feat(rekey): gate sender switch on peer readiness or 2s timeout, both directions"
```

---

### Task 5: WIRE_SPEC.md + on-device verification

**Files:**
- Modify: `WIRE_SPEC.md` (this repo's own copy — NOT synced automatically with Android's; apply the same §8.7 v1.2 update Android's copy already got, verbatim in substance).

- [ ] **Step 1: Update `WIRE_SPEC.md` §8.7** to the same v1.2 content Android's copy has (`qaudion-android-new/WIRE_SPEC.md`, already updated 2026-09-04) — copy its language, this is meant to be identical across repos.
- [ ] **Step 2: Commit** the doc update separately.
- [ ] **Step 3: On-device verification** (two real iPhones, or one iPhone against the Android build through a real call past ~5 min) — same acknowledged-gap posture as Android's fix: valuable, not a blocker, per that fix's final reviewer's own judgment. Note in your report whether this was attempted or deferred, and why.
