# Re-key media deafness (skew) — iOS port

Date: 2026-09-04
Status: approved (Pavel: "fix completo su 3 piattaforme", Android already
shipped). This is the iOS port.
Shared invariant with Android (already shipped, `qaudion-android-new`,
commits through `98beab386`, `WIRE_SPEC.md` §8.7 v1.2 — READ THAT FILE'S
§8.7 section first, it's the wire contract both platforms must agree on):
`call_media_ready` gains a `media: "audio"|"video"` field and now fires on
EVERY re-key (not just the first key of a call), gating a DEFERRED sender
switch instead of the immediate combined install+switch every platform has
today. Per [[feedback_shared_invariant_across_platforms]] the MECHANISM
below is iOS-idiomatic, not a transliteration of the Kotlin — only the wire
field names and semantics must match byte-for-byte.

## What was verified against real iOS code before writing this (not assumed)

Read in full: `NativeVideoFrameCryptor.swift`, `NativeAudioFrameCryptor.swift`
(both in `QAudionEngine/Sources/QAudionEngine/WebRTC/`),
`QAudionWebRtcCallController.swift`'s `ensureVideoSealer` (video rekey call
site) and the audio installation call site around `activateNativeAudioSrtp`,
`BCryptoWebSocketClient.swift`'s `call_media_ready` handler (~L786-800),
`BCryptoCallingApiImpl.swift`'s `sendCallMediaReady` (~L740-759), and
`AppState.swift`'s `sendCallMediaReadyOnce`/`mediaReadySentKeys`/the
`onCallMediaReady` wiring (~L1422-1490, ~L5927-5931, ~L6782-6890,
~L7209-7222, ~L16038-16040).

Confirmed facts, not assumptions:

- **iOS shares ONE epoch counter for BOTH media kinds** —
  `QAudionWebRtcCallController.pqcSessionKeyEpoch: Int32`, set from
  `AppState.callPqcRekeyEpoch` at every one of its 5 call sites (grepped:
  `AppState.swift:6375,6707,14383,17245,21198`), and read by BOTH the video
  rekey branch (`ensureVideoSealer`, `QAudionWebRtcCallController.swift:3085,
  3161`) and the audio install/rekey call (`:2894`). This is a genuine
  architecture difference from Android, which tracks `videoKeyEpoch`/
  `audioKeyEpoch` as two independent `AtomicLong`s and states in its own
  design doc that "video and audio rekey independently." On iOS today they
  never actually diverge — both media kinds always rotate together, driven
  by the one shared PQC session-key rotation.
- **`NativeVideoFrameCryptor.setKey(_:slot:)` and
  `NativeAudioFrameCryptor.setKey(_:slot:)` each combine install+switch in
  one call**, structurally identical to Android's pre-fix
  `rekeyVideoCryptor`/`rekeyAudioCryptor`:
  ```swift
  public func setKey(_ kVideo: Data, slot: Int32 = 0) {
      ...
      keyProvider.setSharedKey(kVideo, with: slot)  // install
      senderCryptor?.keyIndex = slot                 // switch
      hasKey = true
  }
  ```
  Same defect class Android had: decode-readiness (`setSharedKey`) doesn't
  need the sender-switch (`keyIndex` assignment) to happen at the same
  instant, and today they always do.
- **`setKey` was ALREADY hardened once, 2026-08-30, W-KEYSLOTROTATE** — a
  MORE SEVERE, already-fixed prior bug: iOS used to pin everything to slot
  0 regardless of epoch, so the FIRST mid-call rekey killed audio in BOTH
  directions at once (not just a skew window) — live call `c8416eab`,
  20 minutes of flawless RTP then total audio silence from epoch 1 onward.
  Fixed by explicit `slot = pqcSessionKeyEpoch % 16` at every call site.
  This spec's fix is layered on TOP of that — it does not touch the
  slot-numbering fix, only the install/switch timing.
- **`call_media_ready` is a plain `[String: Any]` dictionary on the wire**
  (`BCryptoWebSocketClient.swift`'s handler reads `data["call_id"] as?
  String` etc., `BCryptoCallingApiImpl.swift`'s sender builds a literal
  `["call_id": ..., "mid": ..., "key_epoch": ..., "dir": ...]` dict) — no
  strongly-typed codec layer like Android's `WsCommand`/`WsCodec`. Adding a
  field is a one-line dictionary key on each side, no schema migration.
  **Caution for whoever implements this**: `data["media"]` is ALREADY used
  by the UNRELATED `call_upgrade_intent` handler a few lines above (means
  "camera"/"screen" there, media-consent v1) — same key name, different
  message type, different meaning. Not a collision (each message type has
  its own dict), but don't let a repo-wide grep for `"media"` confuse the
  two.
- **Send-side dedup is `mediaReadySentKeys: Set<String>` in `AppState.swift`,
  keyed per call+mid, sends ONCE ever** (`sendCallMediaReadyOnce`,
  ~L6789-6805) — same "fire once" limitation Android had before its fix.
  Cleared on hangup (`mediaReadySentKeys.removeAll()`, ~L16040) — Android's
  equivalent needed a similar per-call reset for its NEW per-epoch gate
  state, added as a fix during that review; expect the same need here.
- **No audio equivalent of the video "receiver ready" signal exists on iOS
  at all** — same gap Android had before its fix. `onCallMediaReady`'s
  payload is discarded down to just `(callId, senderId, kind)` at the one
  place it's consumed for anything other than `releaseVideoTxHold`
  (`AppState.swift:5927-5931`, `:6878-6881`) — `keyEpoch`/`dir` are
  received off the wire but never read on the inbound side today.
- **CLAUDE.md §16 constraint** (referenced directly in
  `NativeVideoFrameCryptor.swift`'s own file kdoc): a new file in
  `QAudionEngine` must take only `RTC*`/`Data`/`String` params, NEVER
  `AppState`, to avoid tripping a Sendable-inference build break. The new
  Swift port of Android's `RekeySwitchGate` must live in `QAudionEngine`
  (not `QAudionApp`) and must not reference `AppState` — same discipline
  every other file in this neighborhood already follows.

## The fix (iOS-idiomatic port of the shipped Android mechanism)

### 1. Split `setKey` into `installKey` + `switchSender` on both cryptors

```swift
// NativeVideoFrameCryptor.swift / NativeAudioFrameCryptor.swift, mirrored
public func installKey(_ key: Data, slot: Int32) -> Bool {
    guard key.count == 32 else { ...; return false }
    lock.lock(); defer { lock.unlock() }
    currentKeyIndex = Int(slot)
    keyProvider.setSharedKey(key, with: slot)
    hasKey = true
    return true
}

public func switchSender(slot: Int32) {
    lock.lock(); defer { lock.unlock() }
    senderCryptor?.keyIndex = slot
}
```
Remove `setKey` entirely once both call sites (video's `ensureVideoSealer`,
audio's install path) are updated to call `installKey` immediately followed
by an eventually-deferred `switchSender` — do NOT keep `setKey` as a
compatibility wrapper (same "no wrapper" discipline the Android plan used).

### 2. Port `RekeySwitchGate` to Swift

New file `QAudionEngine/Sources/QAudionEngine/Call/RekeySwitchGate.swift`
(next to the existing `ReKeyScheduler.swift` in the same directory). Same
public surface as Android's (`arm`, `currentPendingEpoch`, `attemptSwitch`),
same correctness properties (idempotent, exact-epoch-match, no
double-switch/skipped-epoch — Android's version was hardened against a
TOCTOU race by a code-quality review; port the HARDENED shape, not a naive
first draft), NSLock-guarded state instead of `AtomicReference`+CAS (Swift
has no lock-free CAS primitive as ergonomic as Kotlin's here; a plain
`NSLock` around a small struct is the idiomatic equivalent and this
codebase already uses that exact pattern in both `NativeVideoFrameCryptor`
and `NativeAudioFrameCryptor`):

```swift
public final class RekeySwitchGate: @unchecked Sendable {
    private struct State { var pendingEpoch: Int32 = -1; var switchedEpoch: Int32 = -1 }
    private var state = State()
    private let lock = NSLock()

    public init() {}

    public func arm(_ epoch: Int32) {
        lock.lock(); defer { lock.unlock() }
        state.pendingEpoch = epoch
    }

    public func currentPendingEpoch() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return state.pendingEpoch
    }

    public func attemptSwitch(_ epoch: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch == state.pendingEpoch, state.switchedEpoch < epoch else { return false }
        state.switchedEpoch = epoch
        return true
    }
}
```
Since `attemptSwitch` holds the lock for its ENTIRE check-and-mutate body
(unlike Android's CAS-retry-loop, which only needed the loop because two
independent atomics couldn't be updated together), a plain mutex critical
section is sufficient here and is simpler than porting a CAS loop —
equivalent correctness, more idiomatic Swift. `arm` also takes the lock,
so it can never interleave with an in-flight `attemptSwitch` — this closes
the exact TOCTOU class Android's review found, by construction, not by
replicating Android's specific fix mechanism.

**Test file**: `QAudionEngine/Tests/QAudionEngineTests/Call/RekeySwitchGateTests.swift`
— port Android's 10 test cases (first-attempt-switches, second-attempt-
no-op, ready-before-timeout-wins, timeout-before-ready-wins, stale-epoch-
rejected-and-does-not-block-later, premature-epoch-rejected-and-does-not-
block-later, no-epoch-skipped, currentPendingEpoch-reflects-arm) using
XCTest, same assertions, same intent.

### 3. Wire schema — additive `media` field on the dictionary

`BCryptoCallingApiImpl.sendCallMediaReady` gains a `media: String`
parameter (no Swift default needed the way Kotlin uses one, since callers
are updated explicitly — but DO give existing call sites an explicit
`media: "video"` argument rather than silently changing behavior for any
call site the implementer doesn't find, per the "grep before assuming"
discipline this whole feature has followed):
```swift
public func sendCallMediaReady(
    callId: String, recipientId: String, mid: String,
    keyEpoch: Int, dir: String, media: String
) async throws {
    ws.send(type: "call_media_ready", data: [
        "call_id": callId, "recipient_id": recipientId, "mid": mid,
        "key_epoch": keyEpoch, "dir": dir, "media": media,
    ])
}
```
`BCryptoWebSocketClient`'s `onCallMediaReady` closure signature gains a
`media: String` trailing param, read as `(data["media"] as? String) ??
"video"` (absent ⇒ "video", matching Android's null-default exactly) —
update the closure type AND every place it's assigned/invoked
(`AppState.swift` currently has it as a 5-arg closure discarding 3 of the
5; it needs to become a 6-arg closure that ACTUALLY uses `keyEpoch`/`dir`/
`media` now, not just `callId`/`senderId`).

### 4. Extend the dedup + gate the sender switch

Replace `mediaReadySentKeys`'s fire-once-per-(call,mid) semantics with a
fire-once-per-(call, media, epoch) semantics for the `keyEpoch > 0` case
specifically, while leaving the ORIGINAL epoch-0 first-key behavior
untouched (same "two separate concerns on the same field" split Android's
final review had to correct — get it right the first time here by reading
that lesson: `keyEpoch > 0` is NOT proof of a rekey-ready by itself if any
OTHER path on iOS ever re-sends the live epoch for a non-rekey reason —
check `reannounceCallMediaReadyForSelfHeal` at `AppState.swift:7216`
carefully, it looks like it re-sends via the SAME `sendCallMediaReadyOnce`
dedup-bypass path Android's `reannounceInboundVideoReady` used, which is
EXACTLY the function whose nonzero-epoch reannounce Android's bug swallowed
— gate iOS's new rekey-ready branch on the relevant `RekeySwitchGate`
actually being armed for that exact epoch, from day one, not on
`keyEpoch > 0` alone).

Two new `RekeySwitchGate` instances (mirroring Android's one-per-media-kind
shape even though both will typically be armed to the same epoch value on
iOS today, given the shared `pqcSessionKeyEpoch` — this keeps the mental
model identical across platforms and costs nothing, and if iOS ever splits
its epoch tracking later this code needs no rework). Where these two
instances live (a `QAudionWebRtcCallController` property, most likely,
alongside `pqcSessionKeyEpoch`) and exactly how `hangup`/call-teardown
resets them is an implementation decision for whoever writes the task —
read `QAudionWebRtcCallController`'s teardown path first (search for
where `pqcSessionKeyEpoch` itself gets reset across calls, if it does, and
mirror that reset site) rather than guessing a location.

On deriving a new epoch's key (both the video and audio install call
sites): call `installKey` immediately, `arm()` the relevant gate, send
`call_media_ready` with the new `media`+`keyEpoch`, and race a 2-second
timeout (`DispatchQueue`/`Task.sleep` — whichever this file's existing
idiom uses; check `QAudionWebRtcCallController`'s existing 2s TX-hold
timeout implementation, `~L1598,1741,1768`, and reuse the SAME mechanism
rather than introducing a second timer idiom into the same file) against
`attemptSwitch`, calling `switchSender` on whichever side wins.

## Safety checks (same independent security review Android's design got — properties, not the specific fix, carry over)

Reviewed for Android (nim.ps1 -Mode security, 2026-09-03): no
confidentiality/integrity exposure from an unauthenticated ready signal
(carries no key material, key is already handshake-authenticated), worst
case an adversary forces is the same bounded 2s delay every peer already
tolerates. The three REQUIRED correctness properties, verified for
Android's Kotlin port and required again here:
- Idempotent switch: `attemptSwitch` returns true at most once per epoch.
- Exact-epoch match: a stale or premature epoch is rejected WITHOUT
  mutating gate state (so it never blocks the actually-pending epoch from
  switching later).
- No skipped epoch: the 2s timeout always eventually fires if ready never
  arrives, so every epoch is passed through in order.
The Swift port's single-critical-section `attemptSwitch` (holding one lock
for the whole check-and-mutate) satisfies all three by construction more
directly than Android's CAS-loop did — verify this by porting Android's
exact test cases (already listed above), not by re-deriving new ones.

## Cross-platform scope

This closes the iOS leg. Desktop is a separate, later effort (its own
investigation+spec+plan). Until Desktop ships this, an iOS↔Desktop or
Android↔Desktop call degrades cleanly to the pre-fix bounded skew — no
platform's fix depends on any OTHER platform having shipped theirs first,
by design (the 2s timeout is the fallback for exactly that case).

## Testing

`RekeySwitchGateTests.swift` (pure, XCTest, no WebRTC scaffolding needed —
mirrors Android's approach of testing the pure coordination class directly
rather than the WebRTC-integrated call sites, which this codebase's own
existing tests already avoid doing for the same class of native-cryptor
code — check `NativeVideoFrameCryptor`'s own test coverage, if any exists,
before assuming what's testable vs. not). On-device live-call verification
(two real iPhones, or one iPhone against the already-fixed Android build,
through an actual re-key ~5 min in) is the same acknowledged-gap posture
Android's fix shipped with — valuable, not a blocker, per that fix's final
reviewer's own explicit judgment.

## Out of scope

Server: unchanged (per Android's own verification, the Go relay decodes
`call_media_ready` into a generic map and forwards it whole — an additive
field survives untouched regardless of which platform sent it). No new
server-side field validation is expected or needed.
