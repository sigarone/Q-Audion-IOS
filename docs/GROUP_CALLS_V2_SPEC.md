# Group calls v2 — client contract and iOS notes

Status: v2.0. Replaces the LiveKit group-call path entirely; there is no backward
compatibility (old clients and old wire messages are removed, not tolerated). This file is the
client-side subset of the cross-platform spec (server, Android, iOS, desktop share the same
contract) plus what the iOS implementation does about it. Host names, addresses and ids in
this repository are always placeholders.

## 0. Summary

- Group calls (>= 3 participants, and every 1:1 promoted to a group) run over **qjanus**: Janus
  VideoRoom v1.4.2 on BoringSSL with a DTLS patch (fail-closed transport level).
- Each client keeps exactly **2 PeerConnections per group call**: one publisher (send-only) and one
  multistream subscriber (receive-only, all remote streams).
- Transport level on every client <-> qjanus hop equals the 1:1 level: DTLS 1.3 only,
  `TLS_AES_256_GCM_SHA384` only, `X25519MLKEM768` only, SRTP `AEAD_AES_256_GCM` only. qjanus
  enforces it and the client checks it after connect (section 4.5).
- Content E2EE: every audio/video frame is encrypted with the per-sender, per-epoch media key
  using the SAME frame format as 1:1 (native FrameCryptor, HKDF mode, AES-256-GCM).
  qjanus never sees keys or plaintext.
- iOS uses ONLY the strict M150 WebRTC binary (`import WebRTC`, `RTC*`) through the ONE
  `RTCPeerConnectionFactory` shared with 1:1 calls. The LiveKit SDK, the WS-relay group audio
  fallback and the v1 group-call key derivations are deleted.

## 2. Server <-> client WebSocket messages (JSON, over the authenticated app WebSocket)

Removed: `group_call_sfu_token`, `group_call_sfu_token_recv`, `group_call_sfu_unavailable`,
`group_call_forward`, `group_call_frame`, `group_call_subscribe`, `group_call_unsubscribe`,
`group_call_state`, `group_call_receive`. The `supports_group_sender_keys` /
`supports_raw_key_aes256` fields are gone (always true).

- `group_call_update` (S->C): `{call_id, participants:[user_id], sender_key_epoch:<uint32>,
  media:{node_id, pseudonyms:{<user_id>:<32 hex>}}}` — `sender_key_epoch` bumps on EVERY roster
  change; `media` exists once the room exists. Pseudonyms are 128-bit random, per call per
  participant, never logged in full (8 chars max).
- `group_call_media_join` (C->S) `{call_id}` -> `group_call_media_ready` (S->C, requester only):
  `{call_id, node_id, ws_url (wss only), room, pseudonym, session_token, join_token,
  dtls_fingerprint ("sha-256 AB:CD:..."), ice_servers, ttl_s}`.
- `group_call_media_unavailable` (S->C): `{call_id, reason: no_node|room_create_failed|not_member|full}`.
  No relay fallback: the client shows a clear error and leaves the call.
- `group_call_media_moved` (S->C, all members): the room moved to another node; clients tear
  down both PCs and send `group_call_media_join` again (keys unchanged, no epoch bump).
  `group_call_media_rejoin` (C->S) `{call_id, reason}` is the same request plus a hint that the
  current node failed.
- `group_call_decline` (C->S) `{call_id}`; server ring timeout 45 s per invitee, after which the
  invitee devices get `group_call_ended {reason:"ring_timeout"}`.
- `group_call_media_refresh` (C->S) `{call_id}` -> `group_call_media_token` (S->C) `{call_id,
  session_token, ttl_s:600}` (spec section 11): Janus re-validates the signed session token on EVERY
  request, keepalive included, so a client with a Janus session asks for a fresh one every 300 s and
  once more before it reconnects the media WebSocket; the newest token is used for every later
  request. A requester that is no longer a member gets `group_call_media_unavailable
  {reason:"not_member"}`, which ends the media.
- The per-call TURN credentials live about 2 h: every hour a running call sends a plain
  `group_call_media_join` and applies the answer IN PLACE (a `group_call_media_ready` with the same
  room, node, pseudonym and certificate, within 5 minutes of that request, is the answer of the
  refresh and never a new path; any other hand-out replaces the link): the new
  `ice_servers` go to both PeerConnections through `setConfiguration`, the fresh `session_token`
  replaces the old one, the media is not touched. An unanswered refresh is asked again after 60 s
  (three attempts a round); a `throttled` answer to it does not cost the live link.

## 4. Client Janus protocol

- 4.1 Session: WebSocket to `ws_url`, subprotocol `janus-protocol`, `create` with the session
  token, keepalive every 25 s, random 128-bit transaction per request, 8 s timeout per request.
- 4.2 Publisher handle: `join {ptype:"publisher", room, id:pseudonym, display:pseudonym,
  token:join_token}`; create the publisher PC, attach FrameCryptors to every sender BEFORE the
  offer, then `publish {audio, video, descriptions}` with the offer JSEP `{type:"offer", sdp,
  e2ee:true, rid_order:"lmh"}` (spec section 11: both flags live on the JSEP object, never in the
  request body; `rid_order` because our SDP lists the rids l, m, h ascending: without it Janus
  assumes highest-first and substream 0 would be the highest layer; the ICE-restart offer of
  `configure {restart:true}` carries both too). A sender or receiver whose FrameCryptor cannot be
  attached refuses the negotiation (nothing is sent or rendered in the clear).
- 4.3 Subscriber handle (multistream): `join {ptype:"subscriber", room, private_id, streams}` (only
  the private id, no token), Janus offers, the client answers (`start`); `subscribe` /
  `unsubscribe` renegotiate (`updated` + a new offer; a removed mid stays in the SDP as
  `active:false`).
  All renegotiations of a PC are strictly serialized (one queue per PC, debounce 150 ms).
  Receiver cryptors use the publisher pseudonym as participant id, attached BEFORE rendering.
- 4.4 Both PCs: bundle max-bundle, rtcp-mux require, continual gathering. **DTLS pin**: the
  remote `a=fingerprint` in qjanus' SDP MUST equal `dtls_fingerprint`, else both PCs are closed
  (`group.dtls_pin_mismatch`). SDP rules: only `mid`, `rid`, `repaired-rid` and transport-wide-cc
  extmaps survive (allow-list; Janus 1.4.2 has no Cryptex), Opus fmtp `minptime=60;useinbandfec=1;
  usedtx=0;cbr=1;stereo=0;maxaveragebitrate=32000` and `ptime:60` (the 1:1 audio profile: 60 ms /
  32 kbps CBR, FEC floor 10 %, no RED, no DTX). Video: VP8 simulcast 3 encodings `l/m/h` =
  320x180@15 150 kbps, 640x360@20 450 kbps, 1280x720@25 1200 kbps.
- 4.5 Transport self-check on every PC after `connected`: `tlsVersion` = `FEFC`, `dtlsCipher` =
  `TLS_AES_256_GCM_SHA384`, `srtpCipher` = `AEAD_AES_256_GCM` (or the `SRTP_`-prefixed spelling);
  anything else closes the PC (`group.transport_policy_violation`).
- 4.6 Layer / subscription policy (client-driven): substream by tile size (thumbnail 0, grid 1,
  fullscreen/speaker 2), temporal 2; step down one substream immediately on `slowlink`, loss > 5 %
  over 2 s or `availableIncomingBitrate` < 1.2x the layer; step up after 10 s clean; unsubscribe
  off-screen tiles and every remote video while backgrounded; audio is never unsubscribed.
- 4.7 Network change: ICE restart on both PCs at once (publisher `configure {restart:true}` + new
  offer; subscriber `configure {restart:true}`); PC `failed` or not connected within 10 s of a
  restart -> `group_call_media_rejoin`; WebSocket to qjanus lost -> reclaim with backoff
  0.5/1/2/4 s; congestion: audio first, drop to substream `l`, then stop video, never audio.

## 5. E2EE v2

- Epoch: `sender_key_epoch` (uint32) is server-authoritative; keyIndex = epoch mod 16; control
  envelopes with an older epoch are rejected.
- Keys: on each epoch E every member M generates a FRESH random 32-byte key `K[M,E]` (CSPRNG, no
  derivation from previous keys) and sends it to every other current member over the pairwise
  sealed control channel (`opaque_message` wrapper `{"qa_grpcall_ctrl":1,"cmid","blob"}`):
  `{"qa_grp":2,"t":"media_key","g":<call_id>,"e":E,"k":E mod 16,"key":<b64 32 bytes>}`,
  `media_key_nack` (`{g,e}`, "please resend") and `media_key_ack` (`{g,e}`).
- Frame crypto: native FrameCryptor, AES-GCM, HKDF (`aes_key = HKDF-SHA256(K, salt=empty,
  info=128 x 0x00, L=32)`), `sharedKey=false`, participantId = pseudonym, ring 16, no ratchet,
  `discardFrameWhenCryptorNotReady=true`. Unencrypted header bytes: Opus 1, VP8 10 (key frame) /
  3 (delta) so qjanus can detect key frames and simulcast layers.
- Switch-over: receivers install `K[M,E]` at index E%16 as soon as it arrives; sender M switches its
  send index to E%16 when all members acked or after 1500 ms, then forces a video key frame;
  a receiver that sees MISSING_KEY for (M,E) sends `media_key_nack` (max 4, every 2 s).

## 7. Telemetry (ids only: call id 8 chars, pseudonym 8 chars)

`group.media_join {node, ms}`, `group.pc_state {pc, state}`, `group.transport {tls, cipher, srtp,
cand_type}`, `group.transport_policy_violation`, `group.dtls_pin_mismatch`, `group.e2ee {event,
epoch}`, `group.layer {mid, from, to, reason}`, `group.rejoin {reason}`, `group.ice_restart {reason}`.
Plus the shared per-call `call.media.connected` / `call.media.ended` pair.

## 8. Errors (client)

Real VideoRoom codes: 426 no room, 428 no feed, 432 room full, 433 unauthorized (also "requires
e2ee" and a kicked / removed token), 436 id exists. 426 / 433 -> one automatic
`group_call_media_join`, then an error; 432 -> the `full` error; 436 -> error; 428 on a subscribe is
not an error at all (see deviation 1); 8 s request timeout -> one retry, then a rejoin.

## iOS implementation map

| Concern | Where |
| --- | --- |
| Wire messages (`media_ready`, `update`, unavailable reasons) | `GroupCall/GroupCallWire.swift`, `Backend/BCrypto/BCryptoGroupCallManager.swift` |
| Janus JSON / session / VideoRoom | `GroupCall/JanusWire.swift`, `JanusClient.swift`, `URLSessionJanusSocket.swift`, `VideoRoomClient.swift` |
| Serialized renegotiation, pin, self-check, layers, ICE restart | `GroupCall/GroupMediaSession.swift`, `GroupSerialQueue.swift`, `GroupSdpRules.swift`, `GroupTransportPolicy.swift`, `GroupLayerPolicy.swift`, `GroupNetworkPathWatcher.swift` |
| PeerConnections on the shared factory | `GroupCall/GroupPeerConnections.swift`, `WebRtcGroupMediaBackend.swift` |
| E2EE v2 | `GroupCall/GroupE2ee.swift` (envelopes + epoch coordinator), `GroupFrameCryptorHub.swift` |
| Call controller, recovery ladder | `GroupCall/GroupCallController.swift`, `GroupMediaRecoveryPolicy.swift` |
| Audio unit / CallKit path | `GroupCall/GroupAudioUnitDriver.swift`, `NativeAudioSessionGate`, `QAudionApp/AppState.swift` (`startGroupCallAudioPath`) |
| Telemetry | `GroupCall/GroupTelemetry.swift` |

## iOS deviations from the cross-platform spec

1. **Janus error codes (section 8).** The spec lists 428/433 as "room / participant not found,
   token" and 426/436 as "unauthorized". The real VideoRoom codes are 426 = no such room,
   428 = no such feed, 432 = room full, 433 = unauthorized (token / room), 436 = user id exists.
   iOS retries the media join once for 426 / 433 and for the Janus core codes 403 / 458 / 459
   (token refused, session / handle gone: a fresh hand-out repairs them), shows the `full` error
   for 432 and an error for everything else. A 428 on a subscribe (the feed stopped, or has not
   started, publishing between its `publishers` entry and our request) is NOT a broken media
   path: the feed is skipped until its next `publishers` event, and a first subscriber join that
   got it drops that (now unusable) subscriber handle + PeerConnection and starts clean next time.
2. **`group_call_media_unavailable` reason `throttled`.** Besides the four reasons of the spec, the
   client tolerates `throttled` (the server rate-limiting repeated joins of one member): it is
   retried after 2 s (at most 3 times), every other reason is a visible error.
3. **Camera toggle is a `configure`, not a renegotiation.** The publisher PC always carries a
   (disabled) simulcast video transceiver; the camera on/off flips `configure {video}` and the
   capturer. `publish` is sent with `video:false` when the call starts as an audio call.
4. **Publish policy.** Thermal `serious` / `critical` or Low Power Mode keep only the `l+m` / `l`
   encodings active (spec 4.4 "MAY"), uplink congestion steps down one encoding per `slowlink` and
   stops the video publish at the third step (spec 4.7), a clean 30 s resets the steps.
5. **Group screen share from iOS is removed** (v2.0 scope): the ReplayKit broadcast extension existed
   only for LiveKit and is deleted; remote screen shares (`description:"screen"`) are rendered.
6. **1:1 -> group hand-over (make-before-break).** The 1:1 leg stays up until the group publisher is
   connected AND the promoted peer is in the group roster; if the group media does not come up
   within 30 s the group call is abandoned and the 1:1 call stays. A promoted group runs without its own CallKit entry after the 1:1 CallKit call ends (the
   audio session is then activated by the app, `.selfManaged`).
7. **Nack hardening (section 5.4).** `media_key_nack` is answered only for the CURRENT epoch: the
   ring still holds up to 15 older keys of ours, and re-sending one to a member that joined later
   would break the "a joiner never gets a key before its own epoch" rule.
8. **First-connect watchdog (section 4.7).** The spec only names "not connected within 10 s of a
   restart"; a publisher PC that never reaches `connected` after the very first connect asks for a
   rejoin after 15 s as well.
9. **1:1 -> group hand-over timing.** After the group media is up the 1:1 leg waits for the promoted
   peer to appear in the group; if it has neither joined nor had its ring end after 50 s in total
   (server ring timeout 45 s) the 1:1 leg ends anyway.
10. **Capture height decides the layers.** libwebrtc drops the third simulcast layer for a source
    below about 720p, so the camera captures the format closest to 1280x720 and a smaller one
    publishes only l+m (or l): `GroupPublisherPeer.layerCap(forHeight:)`.
11. **VP8 encoder wrapping.** The 1:1 encoder factory wrapped every encoder in
   `KeyframeForcingVideoEncoder`; native builders (VP8 / VP9 / AV1, libvpx simulcast) cannot be
   wrapped, so those three are now returned unwrapped (H.265, the 1:1 codec, is unchanged).
12. **A vanished feed among several (Janus 428).** Janus refuses the WHOLE `subscribe` / subscriber
    `join` when any feed in it is gone. iOS then retries the feeds one at a time and sets aside only
    the ones that really vanished (until their next `publishers` event), instead of treating the
    whole batch as unavailable, which would have silenced every other publisher of the room.
13. **Receivers without a publisher stream.** Every audio / video receiver of the subscriber PC gets a
    FrameCryptor before the answer exists; a receiver that is not a known, enabled publisher stream
    (a removed stream, or one a node injected without a mapping) is bound to a participant id nobody
    holds a key for, so whatever arrives on it is discarded instead of being played in the clear.
    Dropping the subscriber on its own (a refused join) only detaches the receiver cryptors: the
    publisher's sender cryptors keep running.
14. **Audio session of a group call CallKit does not track.** The audio unit driver asks the app for a
    session if none was activated 2 s after the call began (a foreground accept that fell back to the
    direct path, a cold start), never enables a unit the 1:1 leg still holds, takes the unit over
    when the 1:1 leg ends by ANY path, and the app pays the matching deactivation of its own
    self-activation when such a group call ends.
15. **Cross-platform frame-crypto vectors.** `Tests/QAudionEngineTests/GroupCall/Resources/
    group-calls-v2-frame-crypto.json` (byte-copy of the desktop's vectors, synthetic keys only) is
    reproduced by `GroupE2eeKatTests`: HKDF derivation, the frame wire layout with the key index in
    the trailer, and the key-ring scenarios (wrap at epoch 17, missing key vs decrypt failure,
    per-participant rings) driven through the real `GroupE2eeCoordinator`. The frame crypto itself is
    the native FrameCryptor on iOS; the vectors run through the Swift port of the same layout.
