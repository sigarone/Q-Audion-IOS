# Phase 1 Audit — Wire Protocol Alignment

**Date:** 2026-04-20
**Scope:** Task 1.1 WS command set vs Android `WsCommand.kt`
**Auditor:** read-only subagent (no file modified)

## Android source of truth
`D:\users\f10379a\DEV APP\BCRYPTO\Q-Audion Android New\core\core-data\src\main\java\com\bcrypto\qaudion\data\ws\WsCommand.kt` (sealed interface, 25 type constants in companion object, lines 236-259).

## Command coverage matrix

| Android `type` | iOS impl | Evidence | Drift? |
|---|---|---|---|
| `authenticate` | `BCryptoWebSocketClient.authenticate(token:)` | `BCryptoWebSocketClient.swift:182-184` | ✅ |
| `call_offer` | `BCryptoCallingApiImpl.sendCallOffer` | `BCryptoCallingApiImpl.swift:8-10` | ⚠ `recipientId` (camelCase) instead of `recipient_id`; missing `call_id`, `call_type`, `has_video` |
| `call_answer` | `BCryptoCallingApiImpl.sendCallAnswer` | `BCryptoCallingApiImpl.swift:11-13` | ⚠ `recipientId` camelCase; missing `call_id`, `has_video` |
| `call_ice` | `BCryptoCallingApiImpl.sendIceCandidate` | `BCryptoCallingApiImpl.swift:14-16` | ⚠ `recipientId` camelCase; missing `call_id`, `sdp_mid`, `sdp_mline_index` |
| `call_hangup` | `BCryptoCallingApiImpl.sendHangup` | `BCryptoCallingApiImpl.swift:17-19` | ⚠ `recipientId` camelCase; missing `call_id` and `reason` |
| `call_processing` | `BCryptoCallingApiImpl.sendCallProcessing` | `BCryptoCallingApiImpl.swift:30-35` | ✅ snake_case correct |
| `call_ready` | `BCryptoCallingApiImpl.sendCallReady` | `BCryptoCallingApiImpl.swift:40-45` | ✅ snake_case correct |
| `call_upgrade_request` | — | not found | ❌ NEW (Phase 7) |
| `call_upgrade_response` | — | not found | ❌ NEW (Phase 7) |
| `call_video_state` | — | not found | ❌ NEW (Phase 7) |
| `opaque_message` | `sendOpaqueMessage` | `BCryptoWebSocketClient.swift:162-164` | ✅ uses `recipient_id` snake_case |
| `audio_frame` | `sendAudioFrame` | `BCryptoWebSocketClient.swift:166-168` | ✅ snake_case `recipient_id` |
| `video_frame` | — | not found | ❌ NEW (Phase 7) |
| `presence_subscribe` | `BCryptoPresenceManager.subscribe` | `BCryptoPresenceManager.swift:46-58` | ✅ uses `user_ids` |
| `msg_send` | — | not found | ❌ NEW (Phase 8) |
| `msg_delivered` | — | not found | ❌ NEW (Phase 8) |
| `msg_read` | — | not found | ❌ NEW (Phase 8) |
| `msg_typing` | — | not found | ❌ NEW (Phase 8) |
| `group_call_create` | `createGroupCall` | `BCryptoGroupCallManager.swift:79` | ⚠ iOS sends `{call_id, title, invite_user_ids, max_participants}`; Android `WsCommand.GroupCallCreate` defines `{callId, participants, callType}` — schema diverges |
| `group_call_join` | `joinGroupCall` | `BCryptoGroupCallManager.swift:90` | ✅ |
| `group_call_leave` | `leaveGroupCall` | `BCryptoGroupCallManager.swift:96` | ✅ |
| `group_call_forward` | `forwardAudioFrame` | `BCryptoGroupCallManager.swift:115-119` | ⚠ iOS sends `{call_id, target_id, data}`; Android `GroupCallForward` is SFU broadcast `{callId, frame}` — needs server-truth reconciliation |
| `group_call_end` | `endGroupCall` | `BCryptoGroupCallManager.swift:103` | ✅ |
| `ping` | `tickKeepalive` | `BCryptoWebSocketClient.swift:271` | ✅ |

Legend: ✅ present & matching · ❌ missing · ⚠ present with drift

## Findings

### Drifts (must fix before later phases)

1. **camelCase leakage in 1:1 calling envelopes.** `sendCallOffer/Answer/IceCandidate/Hangup` emit `recipientId` (camelCase). Android wire spec is snake_case (`recipient_id`). Server may tolerate it; Android peers won't decode iOS payloads.
2. **Missing `call_id` on 1:1 signalling.** Android requires `callId` on every call envelope. iOS omits it entirely → concurrent-call disambiguation broken. Hangup also lacks `reason`.
3. **Missing `call_type` / `has_video` on `call_offer`.** Even pre-Phase-7, `call_type` is needed for audio-vs-video discrimination (Android defaults `hasVideo=false`).
4. **`sdp_mid` / `sdp_mline_index` missing on `call_ice`.** Non-trickle ICE fails without these.
5. **`group_call_create` schema split.** iOS ↔ Android disagree on shape — recommend reading `bcrypto-server/internal/signaling/messages.go` to establish server-truth, then aligning the client that's stale.
6. **`group_call_forward` schema split.** iOS uses per-target pairwise PQC `{call_id, target_id, data}`; Android uses SFU broadcast `{callId, frame}`. Pairwise is correct for PQC — Android must catch up.

### NEW commands still to add (tracked by later phases)

- Phase 7 (video uplift): `call_upgrade_request`, `call_upgrade_response`, `call_video_state`, `video_frame`.
- Phase 8 (chat): `msg_send`, `msg_delivered`, `msg_read`, `msg_typing`.

### Unexpected iOS commands

- **Outbound:** none. iOS is a strict subset.
- **Inbound-only** (belong to Android's `WsEvent`, not `WsCommand`, so expected): `authenticated`, `pong`, `heartbeat_ack`, `call_ring`, `call_peer_offline`, `call_cancel`, `presence_update`, `group_call_invite`, `group_call_state`, `group_call_receive`, legacy aliases `group_call_update`, `group_call_frame`, `group_call_ended`. Cross-check deferred to Task 1.2.

### Envelope-level checks

- **Shape `{type, data, id}`** ✅ matches Android `WsCodec`.
- **`id` field**: iOS attaches fresh UUID to every outbound but does NOT maintain a correlation map. Pong/heartbeat_ack are recognised by `type`, not `id`. ⚠ Fine today; Phase 8 `msg_send` ack will require a correlation registry.
- **Field naming**: mixed. 1:1 call signalling camelCase (bad); opaque/audio/presence/group-call snake_case (good).
- **`type` strings**: all 14 iOS literals character-exact matches to Android constants — no typos.

## Recommendation for Phase 1.1 closure

Phase 1.1 is **NOT ready to close.** The four 1:1 call signalling methods in `BCryptoCallingApiImpl.swift` are the highest-priority blocker: camelCase + missing `call_id`/`call_type`/`has_video` will break Android interop on the first cross-platform call. Proposed fix order:

1. Extend `CallingApi.swift` protocol signatures to take `callId: String` and (for offer/answer) `hasVideo: Bool`.
2. Rewrite `BCryptoCallingApiImpl` to emit snake_case payloads:
   - `call_offer { call_id, recipient_id, sdp, call_type, has_video }`
   - `call_answer { call_id, recipient_id, sdp, has_video }`
   - `call_ice { call_id, recipient_id, candidate, sdp_mid, sdp_mline_index }`
   - `call_hangup { call_id, recipient_id, reason }`
3. Propagate `callId` through `QAudionCallIntegration.swift` (generate at call initiation, echo on reply).
4. Add a KAT/interop test: hand-rolled JSON emitted by iOS stub → Android `WsCodec.decode` should produce a valid sealed-class instance.
5. Re-run audit; expect all 6 drift rows to clear.

**Blocker note for controller:** these fixes touch `BCryptoCallingApiImpl.swift`, `CallingApi.swift`, `QAudionCallIntegration.swift` — all in the USER's in-progress working tree. Parity agents MUST NOT stage/commit these files. Recommend: (a) document the drift here, (b) surface to the user so they can incorporate the fixes into their workstream, or (c) wait for user's workstream to land then re-audit. The group-call schema splits also need a server-truth check before fixing either client.

## Next in Phase 1
- **Task 1.2** REST endpoint audit vs Android `BCryptoApi.kt`.
- **Task 1.3** Create canonical `PhoneHash` helper (can proceed independently — new file, no user-WT collision).
