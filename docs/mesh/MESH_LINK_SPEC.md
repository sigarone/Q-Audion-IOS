# Q-Audion BLE mesh: link layer and packet specification

Version: mesh-link-spec/1 (2026-10-20)
Status: normative for every client that implements the Bluetooth mesh chat transport.
Test vectors: `mesh-vectors.json`, produced by `gen_mesh_vectors.py` (deterministic).

## 0. Scope

This document defines everything between the radio and the sealed application
payload: discovery, connection roles, the GATT service, the per-link frame size,
flow control, link framing and reassembly, the `MeshPacket` envelope, the
ANNOUNCE control message, relaying, the meaning of a successful send, the order
in which a device establishes its mesh identity, and the diagnostic log events
each implementation emits.

The application payload carried inside `DATA` and `RECEIPT` packets (the sealed
shell, the chat envelope, the receipt and the receive obligations) is defined in
WIRE_SPEC.md section 9 and is not repeated here. Where this document refers to
that payload it only fixes the bytes the link layer sees.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are used as in RFC 2119.

## 1. Identifiers

### 1.1 Node id

A node id is 8 bytes, written as 16 lowercase hexadecimal characters.

    nodeId = SHA-256(identityPublicKey)[0..8]

`identityPublicKey` is the raw 32-byte Ed25519 public key of the device's
long-term identity, the same key the device publishes as its Ed25519 identity
key in its key bundle. Every device MUST derive its own node id from that key,
and MUST derive a contact's candidate node ids from every authenticated copy of
that contact's identity key it holds (directory, in-person pairing, verified
call). The derivation is identical on all platforms; see `nodeIds` in the
vectors.

The broadcast node id is `ffffffffffffffff`. It is a recipient value only and
MUST NOT be used as a sender.

### 1.2 Identity before radio (startup order)

A device MUST NOT put a packet on the air, nor accept one, under any node id
other than the one derived in 1.1. In particular there is no random fallback
id. The order at process start is:

1. Load the identity key, creating it if the account has none yet.
2. Derive the node id.
3. Create the transport with that node id. The transport's node id is
   immutable for the life of the transport object.
4. Start the radio, if the mesh is enabled, the user has consented and the user
   has not switched the antenna off.

If the identity key cannot be read (for example, protected storage is locked),
the radio MUST NOT start. The device retries the sequence when storage becomes
available or at the next foreground transition, and logs `mesh.identity` with
`ok=0` (section 13).

If the identity key changes while the process runs (re-provisioning, account
switch), the transport MUST be stopped and discarded, and a new transport
created with the new node id. A single process-wide source supplies the node id
to every component that needs it: the packet header sender, the sealed `sn`/`rn`
copies, the associated data, and the recipient match on receive. No component
may cache its own copy.

### 1.3 GATT identifiers

| Item | Value |
|---|---|
| Service UUID (primary) | `b7c1a5e0-9d3a-4f6b-8a21-0d1e2f3a4b01` |
| Characteristic UUID | `b7c1a5e0-9d3a-4f6b-8a21-0d1e2f3a4b02` |
| Client Characteristic Configuration descriptor | `00002902-0000-1000-8000-00805f9b34fb` |

## 2. Radio modes

A device runs in exactly one of these modes while the antenna is on.

| Mode | Advertises + GATT server | Scans + connects out | Relays others' packets |
|---|---|---|---|
| FULL | yes | yes | yes |
| DIRECT | yes | yes | no |
| VISIBLE_ONLY | yes | no | no |

Two devices can exchange packets only if at least one of them scans and
connects out. Two VISIBLE_ONLY devices therefore never form a link. Once a link
exists it is bidirectional regardless of which side opened it (the central
writes, the peripheral notifies), so a VISIBLE_ONLY device can exchange its own
messages with any FULL or DIRECT device that connects to it.

Consent to relay other people's traffic gates FULL only. A device whose user
has not consented to relaying SHOULD run in DIRECT, not VISIBLE_ONLY, so that
it can still reach nearby contacts. VISIBLE_ONLY is a user choice (lowest power,
never initiates), not a default.

### 2.1 Pause during a call on a Bluetooth audio route

A call, for this section, is any connected voice or video call on the device,
of this app or of any other app, including a cellular call, from the moment it
connects until it ends. A call that is only ringing is not a call.

While a call is active and the device's call audio uses a Bluetooth device for
input or output (HFP/SCO, LE Audio, hearing aid, or any other Bluetooth audio
port), the device MUST:

- stop scanning and MUST NOT open new outgoing links; attempts that have not
  reached "connected" are cancelled, while links already connected MAY finish
  service discovery and subscription;
- stop advertising;
- keep existing links up, keep sending ANNOUNCE on them at the normal interval,
  and keep sending and relaying packets over them (the outbox retries only over
  existing links).

The pause ends when the call ends or the call audio no longer uses a Bluetooth
device. Discovery MUST then resume within 2 s, unless the antenna is off for
another reason (consent, kill switch, user choice), with two exceptions: a
route that flips back and forth MUST NOT restart discovery more than once per
5 s, so a resume may wait up to 5 s after the previous restart; and a platform
that limits how often scanning may start (Android: 5 starts per 30 s per app)
MUST defer the restart until that limit allows it, and MUST retry once the
limit has passed if a start is refused. Starting the antenna is not a restart.

Rationale: discovery and connection attempts share the 2.4 GHz radio with the
voice link to the car kit or headset; a hands-free link is the most fragile
Bluetooth traffic on the phone. The pause does not change the radio mode
(section 2); it only suspends discovery.

Privacy: the pause is observable. A nearby BLE scanner can see the
advertisement stop for the length of a Bluetooth call, and the `radio.pause` /
`radio.resume` log events (section 13) record when and for how long such calls
happened. Both are accepted properties of this rule.

## 3. Discovery and connections

### 3.1 Advertising

Every mode advertises connectable undirected advertisements containing the
service UUID (section 1.3) in the service UUID list, no device name, no
manufacturer data, no timeout. The advertisement carries nothing else; identity
is learned only from ANNOUNCE after a link is up.

### 3.2 Scanning

FULL and DIRECT scan with a filter on the service UUID. A device MUST tolerate
the advertiser's address changing (address randomisation) and the same physical
peer appearing under several addresses or platform identifiers.

### 3.3 Outgoing connections

- At most 6 outgoing links (central role) at once.
- A connection attempt that has not reached "connected" within 10 s MUST be
  cancelled and its slot freed.
- A connected link that has not completed service discovery and notification
  subscription within 10 s MUST be disconnected.
- An outgoing link that carried no successful frame and received no valid packet
  for 120 s SHOULD be disconnected (it frees the slot for a peer that is
  actually present). Section 3.4 sets the same rule for incoming links.
- If both devices open a link to each other, both links are kept unless they
  provably are one device in both roles (section 3.6); senders prefer the
  outgoing link for a flood (section 6.2) and use every healthy link for a
  direct send.

### 3.4 Incoming connections

- At most 8 incoming links (peripheral role). An incoming link that has not
  subscribed within 30 s is released, also below the cap.
- At the cap, a new connection MAY evict the oldest incoming link that has not
  subscribed to notifications for more than 30 s; otherwise it is refused.
- Where the platform cannot refuse or close a specific incoming link, the
  device MUST ignore that link's frames and MUST NOT write to it.
- A subscribed incoming link that carried no successful frame and received no
  valid packet for 120 s SHOULD be closed, as an outgoing one is (section 3.3).
  The two roles use the same value.

### 3.5 Retry backoff for outgoing connections

After an outgoing attempt to an advertiser fails (connect timeout, discovery or
subscribe timeout, or the link dropped before the first ANNOUNCE was received
on it), the device MUST NOT attempt the same advertiser again before its
backoff expires. The backoff is keyed by the platform identifier of the
advertiser (Android: device address; iOS: peripheral identifier); a different
identifier is a different advertiser.

- The first failure sets a backoff of 15 s; each further consecutive failure
  doubles it, up to 300 s. Each value is randomised by plus or minus 20 %.
- A link on which an ANNOUNCE is received clears the backoff for that
  identifier.
- At most 64 identifiers are remembered; the oldest entry is dropped first.
- The backoff table is in memory only and is cleared when the antenna is
  turned off.

### 3.6 Links that claim one node

The node id in an ANNOUNCE is only a claim (section 8.1: the cipher is an
app-recognition boundary). While ANNOUNCE carries no proof of the node id,
links with different peer addresses that claim the same node id are all kept
open and all used: nothing is closed, excluded or refused because another link
claims the same id. Collapsing them needs proof of identity, which is a later
change to ANNOUNCE.

A link keeps the node id its first ANNOUNCE named. A later ANNOUNCE on the
same link that names another node id is not accepted: the link is closed with
`link.down reason=rebind`, and nothing it carried changes any mapping.

Sends to a node (section 9.1) go to every healthy link bound to it, up to
four. Only above four are they ranked: the link bound to the node earliest
(age counts from the ANNOUNCE that first named the node on that link) first,
then the others by the most recent data activity, ties going to the older bind.
Data activity is a validated DATA or RECEIPT packet RECEIVED on the link; an
ANNOUNCE, a reserved type, a packet that fails decoding and anything this
device sends never counts. A link is healthy when it is subscribed and carried a
frame or received a valid packet within the last 120 s. Receivers already drop
a copy of a message or receipt they have by its message id, so the extra copies
cost air time but change nothing else. A flood (section 9.2) goes to every link
not yet bound to a node and to up to four links of each node, chosen the same
way, and never to any link of the node the packet came from. A relayed packet
whose recipient is directly linked goes only to the links of that recipient.
The `claim` count of `ann.sum` shows how often more than one address claims a
node.

The one case that is closed is a link that provably duplicates another on the
same physical device: the same peer address in the opposite role. Of such a
pair, the link in the role "central is the node with the lower node id" (node
ids compared as lowercase hex strings) stays and the other is closed with
`link.down reason=dup`; both ends reach the same answer. Where the platform
gives the two roles of one device different identifiers, nothing is provably
the same device and nothing is closed. The decision is taken again, at once,
whenever a link bound to a node is bound or goes away, so a link left over is
used at once.

- The address of an outgoing link closed as a same-device duplicate is
  remembered, and is not dialled while a healthy link to its node exists, for
  30 s, then 60, 120 and 300 s for each repeat. The memory is forgotten as soon
  as no healthy link to that node exists. A scan result is also skipped when a
  healthy link exists at that very address; a healthy link to the same node at
  a different address never skips it. No other address is ever suppressed. At
  most 64 addresses are remembered; the oldest goes first.
- A link may be closed as a same-device duplicate at most 4 times in 300 s,
  counted per platform link key (address or identifier), so one peer cannot use
  up the allowance of another. A link the allowance does not let the device
  close stays open but is not used (nothing is sent on it, it gets no periodic
  ANNOUNCE) until the next decision. At most 64 keys are remembered.
- An incoming connection from a central whose link was closed (or, where the
  platform cannot close it, dropped) as a same-device duplicate is refused for
  30 s, and so is one whose link was closed for naming another node id
  (`rebind`). Unsubscribing and subscribing again does not lift this. The
  refusal is keyed by that central's own address, never by a claimed node id,
  so it cannot be used against another device. No incoming connection from
  any other address is refused for this reason.
- At the cap of incoming links (section 3.4) a connection that never
  subscribed is released after 30 s to make room. Otherwise one connection
  beyond the cap (and one outgoing link beyond the outgoing cap) is allowed on
  probation. Only when that link has sent a valid ANNOUNCE and is subscribed
  may it make room, and at most one link per role is evicted per 30 s: a link
  kept open but not used first, then the longest idle link. A link is idle
  since the later of its last validated DATA or RECEIPT and its bind, and is
  evictable once idle for more than 30 s. Never evicted: the newcomer itself,
  any link bound to the node id the newcomer claims, the earliest-bound
  healthy link of a node and the earliest-bound verified link of a node (the
  newcomer is not counted in that decision). With
  no link to evict, the newcomer is closed.
- A link closed by eviction, the newcomer itself included, is remembered: an
  outgoing address is not dialled again for 30 s, then 60, 120 and 300 s for
  each repeat (forgotten after 15 quiet minutes), whether or not a healthy
  link to its node exists; an incoming central is refused for 60 s, or for the
  same growing wait if that is longer. Beyond the outgoing cap only an address
  whose node has no healthy link is dialled, and only when a dry run of the
  eviction choice (leaving the newcomer out) finds a link that could make room and
  the limit of one eviction per 30 s allows it; an incoming connection beyond the
  incoming cap is accepted under the same test.
- A link that subscribed and has not sent a valid ANNOUNCE within 35 s (two ANNOUNCE periods and a frame
  timeout, so one lost ANNOUNCE does not close an honest link) is
  closed, so that it cannot hold a slot (including the probation slot).
- Where the platform cannot close an incoming link (section 3.4), it is dropped
  from the tables and ignored as described there.
- All the timers of this section (bind time, activity, refusals, memories,
  allowance, ANNOUNCE pacing) use a monotonic clock that keeps counting while the
  device sleeps; the timestamp inside a packet is not one of them.
- Links whose node id is proved (section 8.5) rank first above four links. The
  earliest-bound verified link of a node is protected from eviction, as is the
  earliest-bound healthy link of a node. Nothing is left out of a send for
  being unverified.
- The collapse of this section needs no new frame. A peer that does not implement
  it keeps both links open and sees an ordinary disconnect on the closed one.

## 4. GATT service

### 4.1 Characteristic

One characteristic with properties Write, Write Without Response and Notify,
write permission, and a CCCD. Implementations MUST accept both write types on
receive. Indications are not used.

### 4.2 MTU

- An Android central MUST request an ATT MTU of 517 immediately after the
  connection is established and MUST NOT start service discovery before the MTU
  exchange completes (success or failure).
- An Android GATT server MUST record the MTU reported for each connected
  central (`onMtuChanged` of the server callback). Until a value is reported the
  MTU is 23.
- iOS does not expose the MTU directly. The per-link limits in section 5 are
  read from CoreBluetooth instead.
- The value limit MUST be re-read for every packet, not cached for the life of
  the link: a peer may renegotiate.

### 4.3 Subscription and the first ANNOUNCE

- The central subscribes by writing `0x0001` (notifications) to the CCCD.
- The central sends its ANNOUNCE on that link as soon as the CCCD write is
  confirmed (Android `onDescriptorWrite` with success, iOS
  `didUpdateNotificationStateFor` with `isNotifying == true`). A fixed delay is
  not a substitute for the confirmation.
- The peripheral MUST treat a central as subscribed only when the CCCD value
  written is `0x0001` or `0x0003`, and as unsubscribed on `0x0000`.
- The peripheral sends its own ANNOUNCE to a central as soon as that central
  subscribes. Without this the central would not learn who is behind the link
  until the next periodic ANNOUNCE.

## 5. The per-link value limit

`L` is the largest value that may be placed in one ATT operation on a given
link, in a given direction. Every frame on that link MUST be at most `L` bytes
(header included).

| Sender role | Platform | L |
|---|---|---|
| central (write) | iOS | `peripheral.maximumWriteValueLength(for: .withoutResponse)` |
| central (write) | Android | negotiated MTU (from `onMtuChanged` of the client callback) minus 3 |
| peripheral (notify) | iOS | `central.maximumUpdateValueLength` for that subscribed central |
| peripheral (notify) | Android | MTU recorded for that central (section 4.2) minus 3 |

On iOS the `.withoutResponse` variant is used for the central limit even though
frames are sent with response (section 6.2). The `.withResponse` variant
reports the long-write limit (512), and long writes are not allowed.

Long writes (Prepare Write / Execute Write) MUST NOT be produced by a sender. A
GATT server that receives one MUST reject it and MUST NOT feed any part of it to
the reassembler:

- Android: a write request with `preparedWrite == true` or `offset != 0` is
  answered with `GATT_REQUEST_NOT_SUPPORTED` and its value discarded;
  `onExecuteWrite` is answered with `GATT_REQUEST_NOT_SUPPORTED`.
- iOS: if any request in a `didReceiveWrite` call has a non-zero `offset`, the
  whole call is a long write; every value in it is discarded and the call is
  answered once, on the first request, with `.invalidOffset`. Otherwise each
  request value is one frame, and the call is answered once, on the first
  request, with `.success` (CoreBluetooth expects one response per call).

If `L - 4 < 16` the link is not usable for packets larger than one frame; a
sender MAY still send single-frame packets on it.

## 6. Link framing

### 6.1 Frame layout

    offset  size  field
    0       2     setId  (u16, big-endian)
    2       1     index  (u8, 0-based)
    3       1     total  (u8, 1..255)
    4       n     chunk  (n >= 1)

A packet (section 7) is encoded once and split into `total = ceil(len / C)`
frames where `C = L - 4` for the link it is sent on. Frame `i` carries bytes
`[i*C, min((i+1)*C, len))`. If `total` would exceed 255 the packet MUST NOT be
sent on that link and the send fails for that link with reason `too_many_frames`.
`setId` is chosen uniformly at random for every transmission of every packet on
every link set; a retransmission of the same packet uses a new `setId`.

The same packet may be split differently on different links (different `L`).
A receiver MUST NOT assume that all frames of a set have the same size or that
the chunk size equals its own limit.

See `frames` in the vectors for the splitting of two packets at L = 20, 182,
244 and 509.

### 6.2 Sender rules

- Prefer the outgoing (central) link to a peer over an incoming one.
- Central to peripheral: every frame is an ATT Write Request (iOS
  `.withResponse`, Android `WRITE_TYPE_DEFAULT`). The next frame on that link is
  issued only after the write callback for the previous one reports success
  (iOS `peripheral(_:didWriteValueFor:error:)` with `error == nil`, Android
  `onCharacteristicWrite` with `GATT_SUCCESS`).
- Peripheral to central: every frame is a notification. On iOS, when
  `updateValue` returns `false` the same frame is retried from
  `peripheralManagerIsReady(toUpdateSubscribers:)`. On Android the next frame is
  issued only after `onNotificationSent` with `GATT_SUCCESS`; on API 33 and later
  the call is `notifyCharacteristicChanged(device, characteristic, false, value)`
  and its return code MUST be `BluetoothStatusCodes.SUCCESS`.
- At most one ATT operation is outstanding per link. Frames of one set are sent
  in index order and a set is finished (or abandoned) before the next set starts
  on the same link. Links are independent of each other.
- A frame not confirmed within 2 s fails the set on that link. The remaining
  frames of that set MUST NOT be sent.
- No fixed sleep between frames is required. Pacing comes from the
  confirmations above; an implementation MAY add a gap of at most 20 ms between
  sets.

### 6.3 Receiver rules

Frames are reassembled per link, keyed by `(link, setId)`.

- A frame shorter than 5 bytes, with `total == 0` or `index >= total`, is
  malformed.
- `total == 1`: the chunk is the packet.
- A frame whose `total` differs from the `total` of the open set with the same
  `setId` discards that set and is malformed.
- A frame whose index is already present is ignored (not malformed).
- A set is complete when all `total` indices are present; the chunks are
  concatenated in index order.
- An incomplete set is discarded 10 s after its most recent frame, and in any
  case 30 s after its first frame.
- At most 4 incomplete sets per link. A new set at the cap evicts the set with
  the oldest most-recent frame.
- A set whose buffered bytes exceed 18457 (the largest possible encoded packet)
  is discarded and is malformed.
- A complete set that does not decode as a packet (section 7.2) is malformed.

### 6.4 Malformed input

Each link keeps a count of consecutive malformed events (the cases above, plus
an ANNOUNCE that fails to decrypt or to parse). A well-formed packet resets it.
At 10 the link is disconnected where the platform allows it, and frames from
that link (address or platform identifier) are ignored for 60 s. The block
survives an antenna restart.

## 7. Packet

### 7.1 Layout

All integers big-endian.

    offset  size        field
    0       1           version          = 1
    1       1           type             (section 7.3)
    2       8           senderId
    10      8           recipientId      (node id or broadcast)
    18      1           flags            bit0 hasTtl, bit1 hasSourceRoute, other bits 0
    ..      1           ttl              present iff bit0
    ..      1           hopCount         present iff bit1, 1..255
    ..      8*hopCount  sourceRoute
    ..      8           timestampMs      (i64, Unix ms)
    ..      4           payloadLength    (u32, 0..16384)
    ..      n           payload

### 7.2 Decoding

A receiver MUST reject (and count as malformed) a packet that:

- is shorter than its declared fields,
- has a version other than 1,
- has a type not listed in 7.3,
- has any flag bit other than bit0 and bit1 set,
- has bit1 set with `hopCount == 0`,
- declares `payloadLength > 16384`,
- has bytes after the payload.

Senders MUST produce exactly this canonical form. See `packetHeaders` and
`packetDecodeNegative` in the vectors.

### 7.3 Types

| Code | Name | Payload | Relayed |
|---|---|---|---|
| 0x01 | DATA | sealed shell (WIRE_SPEC 9.1) | yes |
| 0x02 | FRAGMENT | reserved, not sent; receivers drop | no |
| 0x03 | ANNOUNCE | discovery-wrapped JSON (section 8) | never |
| 0x04 | ACK | reserved, not sent; receivers drop | no |
| 0x05 | RECEIPT | sealed shell (WIRE_SPEC 9.5) | yes |
| 0x06 | ANNOUNCE_PROOF | proof of a node id (section 8.5) | never |

DATA and RECEIPT are originated with `ttl = 5` and no source route. ANNOUNCE
has no ttl and recipient broadcast. ANNOUNCE_PROOF has no ttl and the node id
of the verifier as recipient; it goes to the peer of one link only.

## 8. ANNOUNCE

### 8.1 Cipher

    key   = HKDF-SHA256(ikm  = "Q-Audion-Mesh-Discovery-Shared-Seed-v1",
                        salt = "q-audion-mesh-discovery-salt-v1",
                        info = "q-audion-mesh-discovery-v1", L = 32)
    wire  = nonce(12, random) || AES-256-GCM(key, nonce, plaintext, aad = empty) || tag(16)

The key is a public constant; it distinguishes Q-Audion traffic from arbitrary
BLE traffic and hides nothing from another Q-Audion install. See
`discoveryCipher` and `announce` in the vectors (fixed nonces are used there
only to make the vectors reproducible; on the air the nonce is random).

### 8.2 JSON

    {"v":1,"node":"<nodeId>","fp":"<nodeId>","nbrs":["<nodeId>", ...]}

- Senders emit `v`, `node`, `fp`, `nbrs` in this order, UTF-8, no whitespace,
  and omit `hint`. `fp` equals `node`. `nbrs` lists at most 10 node ids of
  peers this device currently has a live link to (empty list if none). A
  sender that implements section 8.5 appends a sixth member after `nbrs`:
  `"ch":"<32 lowercase hex characters>"`, its challenge on this link, and once
  it has verified the peer's proof on this link, `"pv":1` after it (8.5).
  Receivers read `ch` when it is exactly 32 lowercase hex characters and treat
  anything else as absent (a peer without proofs). They read `pv` strictly: only
  the number 1 counts, a string, a boolean, `1.0` or anything else is absent, and
  `pv` without a valid `ch` is ignored.
- Receivers parse JSON; they MUST NOT depend on key order or escaping. They
  MUST reject when `v` is absent or not 1, when `node` or `fp` is absent or not
  16 lowercase hex characters, or when `node` equals the broadcast id. They MUST
  accept an absent or null `hint` and ignore unknown keys. An absent `nbrs`
  means an empty list; entries that are not valid node ids are ignored; entries
  beyond the first 10 are ignored.
- The header `senderId` of an ANNOUNCE MUST equal `node`; otherwise it is
  malformed.

See `announceJsonAccept` and `announceJsonReject` in the vectors.

### 8.3 Binding a link to a node

The mapping "this link reaches node X" is set only by a valid ANNOUNCE received
on that link. The `senderId` of any other packet type is the originator, which
for a relayed packet is not the device at the other end of the link, and MUST
NOT update the mapping. A link with no ANNOUNCE yet is usable for flooding but
not for a direct send.

### 8.4 Timing

ANNOUNCE is sent on link-up (section 4.3) and then every 15 s on every
subscribed or writable link, counted from the previous ANNOUNCE on that link.

The periodic ANNOUNCEs of different links MUST NOT go out at one instant: a
device starts at most one periodic ANNOUNCE per 1 s tick, the link whose last
ANNOUNCE is the oldest first. Links announced together at link-up are thereby
spread over the period, and each keeps its 15 s cadence (up to 1 s late).

### 8.5 Proof of the node id

The node id in an ANNOUNCE is a claim. A device can prove it holds the identity
key behind the node id, in the background, without ever delaying a message.

**Challenge.** When a link is created each end draws 16 random bytes, its
challenge for that link, and sends them as `ch` in every ANNOUNCE on the link
(the same bytes each time). A challenge is never reused on another link.

**Proof packet.** After its own ANNOUNCE (with its challenge) went out on the
link, and once the peer's ANNOUNCE with a challenge has bound the link to a node,
a device sends an ANNOUNCE_PROOF (type 0x06) on that link: header sender = its
own node id, recipient = the peer's node id, no ttl, no route. The payload is 97
bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | version, 0x01 |
| 1 | 32 | the raw Ed25519 identity public key |
| 33 | 64 | the Ed25519 signature (RFC 8032) over the signed message |

A device sends its proof again on later ANNOUNCEs, at most once per ANNOUNCE period
(15 s), until the peer's ANNOUNCE carries `pv=1` (the peer has verified it), and
retries the same way when the signature or the write failed (the identity key
may be unreadable for a while, for example while the phone is locked). What a
device verified of its peer has no effect on this. It stops after 8 sends on one
link whatever happens. `pv` only controls this resending and never changes
routing or ranking. A device checks at most 3 proofs per link and ignores the
rest before they use any budget; each proof checked also counts in the per-link
rate limit of the relay path (section 9.2).

**Signed message.** Fixed layout, 73 bytes, no length prefixes needed:

| Offset | Size | Field |
|---|---|---|
| 0 | 24 | the ASCII string `qaudion-mesh-announce-v1` |
| 24 | 1 | role of the PROVER on this link: 0x01 central, 0x02 peripheral |
| 25 | 8 | node id of the prover |
| 33 | 8 | node id of the verifier |
| 41 | 16 | challenge of the prover (the `ch` it sent on this link) |
| 57 | 16 | challenge of the verifier (the `ch` the prover received on this link) |

**Verification.** The receiver (the verifier) rebuilds the message from the node
id the link is bound to, its own node id, the prover's challenge from the
prover's ANNOUNCE on this link, its own challenge on this link, and the role
opposite to its own. It accepts the proof only if all of these hold: the payload
has 97 bytes and version 1; the first 8 bytes of SHA-256 of the public key equal
the node id the link is bound to (the derivation of section 1.1); the header
sender equals that node id; the signature verifies. Because both challenges and
the role are inside the signature, a captured proof does not verify on another
link, in the other direction, or for another node id.

**Never blocking.** A link is usable from its first ANNOUNCE, exactly as without
proofs. Verification only changes ranking:

- Verified: the link is marked verified.
- No proof yet, or a peer without this section (no `ch`, no proof): the
  link stays unverified and keeps working under the rules of section 3.6.
- A proof that does not verify marks the link failed: it ranks after every other
  link of the node and wins nothing, but it is not closed for that reason, and
  it still carries messages when it is all there is. It is not a malformed
  packet and does not count towards the malformed streak.
- A proof received before the link is bound, or without a challenge on record,
  is ignored.

**Effect.** Verification only ranks links. Nothing is left out of a send for
being unverified: a send, a flood and a relay use every healthy link bound to the
node, up to four, and above four the order is verified, unverified, failed. A
verified link is protected from eviction only if it is the earliest-bound verified
link of its node (section 3.6); every other link, verified or not, can be evicted
under the idle rule.

**What a proof is not.** Bluetooth Low Energy has no channel binding. A device
that sits between two others can forward the ANNOUNCEs and the proofs of one to
the other, and both then see a verified link to a peer that is only reachable
through the relay; a proof does not prevent that, and a link that was verified
may stay believed verified for a while after its peer left. For these reasons a
verified link never excludes the others. What a proof does prevent: claiming a
node id without its key, so squatting on a node id and getting verified links
evicted or displaced by a claimant.

**Key pin.** A device pins the key of each node id that verified, for 10 minutes
(at most 64 node ids). A valid proof for a node id with another key than the
pinned one does not make the link verified: the link is marked failed, and one
`ann.proof` line with the reason `key_change` is written. The pin is not replaced
and not deleted before it expires. The pin and the log are all the cache is for:
a reconnect is not trusted before its proof verifies.

**Logging.** `ann.sum` carries the number of verified and unverified bound links
and the number of failed proofs of the window; one `ann.proof` line per link
whose proof did not verify carries a short reason token. No key, challenge or
signature is ever logged.

See `announceChallenge` and `announceProof` in the vectors (section 14). Ed25519 is RFC 8032; a library may add
randomness to the signature (CryptoKit does), so implementations are held to the vector by verifying the vector's signature
and, where the library is deterministic, by producing its exact bytes.

## 9. Delivery and relaying

### 9.1 For this device

A packet is for this device when `recipientId` equals the device's node id or
the broadcast id. DATA and RECEIPT for this device are handed to the
application layer (WIRE_SPEC 9.4 and 9.5); the application layer deduplicates
by the shell's `c`.

### 9.2 Relay conditions

A packet is relayed only if all hold:

- the mode is FULL;
- the type is DATA or RECEIPT;
- `recipientId` is not this device;
- `senderId` is not this device;
- `ttl` is present and greater than 0;
- the packet has not been relayed before by this device (identity: senderId,
  recipientId, type, timestampMs and a hash of the payload; ttl excluded; at
  least the last 256 identities remembered);
- the immediate link has relayed at most 20 packets through this device in the
  current 10 s window;
- the relay probability draw succeeds (9.3).

The relayed packet is identical except `ttl - 1`, is re-encoded, re-split for
each outgoing link, and is sent to every link except the one it arrived on. A
relay that fails on a link is logged and not retried.

### 9.3 Relay probability

With `n` the number of distinct nodes currently linked and `t` the received ttl:

    p = 1                                       if n <= 4
    p = clamp(4/n + clamp(t/5, 0, 1) * (1 - 4/n), 0.15, 1)   otherwise

See `relayProbability` in the vectors.

## 10. What "sent" means

### 10.1 Frame and packet results

- A frame is accepted when the confirmation in section 6.2 arrives with
  success. Anything else (refused, oversized, timed out, link lost) is a
  failure.
- A packet is accepted on a link only if every frame of its set was accepted on
  that link.
- A direct send succeeds only if the packet was accepted on the chosen link. A
  flood succeeds if the packet was accepted on at least one link. The transport
  reports `sentDirect`, `sentViaRelay`, `queued(reason)` or `failed(reason)`,
  and the number of links on which the packet was accepted.
- A send to a peer that has a known but non-writable link falls back to a
  flood.

### 10.2 Application states

| State | Meaning |
|---|---|
| sending | sealed, waiting for a link or in the outbox |
| sent | accepted by the first hop (10.1) |
| delivered | a valid delivery receipt arrived |
| read | a valid read receipt arrived |
| failed | outbox gave up (default 1 hour) |

Acceptance by the first hop is not delivery. A message stays in the outbox
after it is sent and is retransmitted every 20 s until a delivery receipt
arrives or the outbox gives up. A retransmission is a new packet (new
`timestampMs`, so relays do not suppress it as a duplicate, and new `setId`)
carrying the same sealed shell, so the receiver's duplicate check on `c` makes
a second copy harmless. Receipts that cannot be sent immediately are also queued; a
newer receipt for the same message and kind replaces a queued one.

## 11. Unknown senders

A DATA or RECEIPT whose `senderId` does not resolve to a contact is dropped
without a decryption attempt (WIRE_SPEC 9.4). Before dropping, a device SHOULD
refresh its authenticated identity keys for its contacts from the directory, at
most once per 60 s across all callers, and retry the lookup once. It MUST NOT
name or trust a device on the strength of an ANNOUNCE alone.

## 12. Background operation (platform notes)

- iOS suspends CoreBluetooth scanning, advertising and GATT callbacks for an app
  without the `bluetooth-central` / `bluetooth-peripheral` background modes. An
  iOS device without those modes is reachable only while the app is in the
  foreground, and the user interface MUST say so rather than show the peer as
  reachable.
- With `bluetooth-peripheral`, a backgrounded iOS device advertises its service
  UUID only in a platform-specific overflow area that non-Apple scanners do not
  match. A backgrounded iOS device is therefore discoverable by Android only if
  the iOS device itself connects out (`bluetooth-central`, scanning with the
  service UUID filter). Android devices MUST keep advertising while the antenna
  is on so that this path works.
- With `bluetooth-central`, background scans coalesce duplicates and run at a
  lower duty cycle; discovery takes longer. State restoration
  (`CBCentralManagerOptionRestoreIdentifierKey`,
  `CBPeripheralManagerOptionRestoreIdentifierKey`) is required for the system
  to relaunch the app for mesh events.
- Android keeps the radio running only while the process is alive; a
  foreground service is needed for reliable background operation.

## 13. Diagnostic log events

Each implementation emits these events at INFO level (WARN where marked),
under the log tag/category `mesh`, as one line `mesh <event> key=value ...`.
Values are integers, booleans as 0/1, or the enumerated tokens listed. The
events are shippable through each platform's remote-log pipeline and MUST be
admitted by its source allow-list.

Never logged: full node ids, BLE addresses or platform peer identifiers, user
ids, conversation ids, message or receipt ids, payload or frame bytes, keys,
display names. The only identifiers allowed are:

- `nh`: the first 6 hex characters of a node id;
- `link`: a per-process link handle (`c1`, `c2`, ... for outgoing, `p1`, `p2`,
  ... for incoming), never reused within the process;
- `ph`: the first 8 hex characters of SHA-256 of a packet's payload, which is
  stable across relays and lets a sender's transmission be matched with a
  receiver's arrival.

| Event | Fields |
|---|---|
| `identity` | `ok`, `nh`, `src` (`key`, `locked`, `missing`) |
| `radio` | `state` (`off`, `starting`, `on`, `error`), `mode` (`full`, `direct`, `visible`), `reason` |
| `link.up` | `link`, `role` (`c`, `p`), `n` (links now) |
| `link.ready` | `link`, `mtu` (Android, 0 if unknown), `l` (value limit L), `sub` |
| `link.down` | `link`, `reason` (`remote`, `timeout`, `evicted`, `blocked`, `stop`, `dup`, `rebind`), `heldMs` |
| `link.refused` | `reason` (`cap`, `blocked`), `role` |
| `ann.tx` | `link`, `nbrs`, `bytes`, `ok`; only for the ANNOUNCE sent at link-up (section 4.3) |
| `ann.rx` | `link`, `nh`, `nbrs`, `bound` (always 1); only when the link-to-node mapping changed |
| `ann.sum` | `tx`, `fail` (of `tx`, not confirmed), `rx`, `links`, `claim` (nodes claimed from more than one distinct address in the window), `ver` and `unv` (bound links that are verified, and that are not), `badsig` (proofs that did not verify in the window), `s` (window in seconds); one line per 60 s, none when nothing was sent or received. Counts every ANNOUNCE, so the periodic ones need no line of their own |
| `ann.proof` | `link`, `reason` (`bad_sig`, `bad_node`, `bad_len`, `bad_ver`, `key_change`); one line per link whose proof did not verify |
| `tx` | `ph`, `type`, `bytes`, `route` (`direct`, `flood`), `links`, `okLinks`, `frames`, `l` (min L used), `result` (`sent`, `queued`, `failed`), `reason`, `ms` |
| `tx.frame.fail` (WARN) | `link`, `ph`, `idx`, `total`, `reason` (`too_big`, `rejected`, `timeout`, `not_ready`, `link_lost`, `too_many_frames`), `rep` (only when above 0: failures on the same link and reason withheld meanwhile; at most one line per link and reason per 60 s) |
| `rx` | `link`, `ph`, `type`, `bytes`, `frames`, `forUs`, `relay` (0/1) |
| `rx.drop` (WARN) | `link`, `reason` (`short_frame`, `bad_header`, `total_mismatch`, `set_expired`, `set_evicted`, `set_too_large`, `decode`, `ann_decrypt`, `ann_parse`, `blocked`) , `streak` |
| `guard.block` (WARN) | `link`, `streak`, `ms` |
| `relay` | `ph`, `ttl`, `p` (permille), `fwd`, `okLinks`, `reason` (`rate`, `dup`, `mode`, `ttl`) |
| `app.tx` | `ph`, `kind` (`msg`, `rcpt`), `state` (`sent`, `queued`, `failed`), `attempt` |
| `app.rx` | `ph`, `kind`, `result` (`stored`, `dup`, `unknown_sender`, `refresh_hit`, `undecryptable`, `bad_envelope`, `readdressed`, `service`, `blocked`, `applied`) |
| `outbox` | `pending`, `retried`, `gaveUp` |
| `radio.pause` | `reason` (`bt_call_route`) |
| `radio.resume` | `reason` (`call_ended`, `route_changed`), `pausedMs` |
| `connect.backoff` | `link`, `failures`, `waitMs` |

`tx` is emitted once per packet transmission attempt, after every frame has a
result. `app.tx` is emitted when an application-level state changes.

## 14. Test vectors

`mesh-vectors.json` contains:

| Section | Use |
|---|---|
| `constants` | values of this document |
| `nodeIds` | identity key to node id |
| `packetHeaders` | field values and exact encoding; decode must round-trip |
| `packetDecodeNegative` | inputs that MUST be rejected, with the reason |
| `discoveryCipher` | HKDF inputs and the derived key |
| `announce` | canonical JSON, fixed-nonce ciphertext, full ANNOUNCE packet |
| `announceDecryptNegative` | ciphertexts that MUST fail to open |
| `announceJsonAccept` / `announceJsonReject` | parser tolerance |
| `announceChallenge` | canonical JSON of an ANNOUNCE with `ch`, and with `ch` and `pv` |
| `announceProof` | fixed Ed25519 seeds, nonces, node ids and role: the exact signed bytes, signature, payload and packet; one extra signature made by CryptoKit on iOS (`externalSignatures`) that every implementation MUST verify; and proofs that MUST NOT verify (other role, other link, wrong node id, bad signature, bad length or version) |
| `envelope`, `receipt`, `shell` | canonical JSON bytes, accepted variants, rejects |
| `aad` | associated-data strings (WIRE_SPEC 9.3) |
| `frames` | splitting of two packets at L = 20, 182, 244, 509 |
| `frameLimits` | frame-count limit and an unusable link |
| `reassembly` | per-frame receiver status and completed packets |
| `relayProbability` | values of section 9.3 |

Canonical JSON is the generator's output (insertion order, no whitespace, UTF-8,
`/` not escaped). Encoders SHOULD produce it; decoders MUST accept any valid
JSON with the same members, which is what the "accepted variants" exercise.
The `e` member in the shell vectors is an opaque placeholder, not ratchet
output; ratchet vectors live with the ratchet.

## 15. Constants

| Name | Value |
|---|---|
| node id size | 8 bytes |
| frame header | 4 bytes |
| max frames per set | 255 |
| max payload | 16384 bytes |
| max encoded packet | 18457 bytes |
| default ttl | 5 |
| Android requested MTU | 517 |
| frame confirmation timeout | 2 s |
| connect timeout | 10 s |
| discovery + subscribe timeout | 10 s |
| idle link, either role | 120 s |
| outgoing links | 6 |
| incoming links | 8 |
| unsubscribed incoming eviction age | 30 s |
| reassembly idle / absolute | 10 s / 30 s |
| incomplete sets per link | 4 |
| malformed streak / block | 10 / 60 s |
| relay window | 20 per 10 s per link |
| relayed identities remembered | 256 |
| ANNOUNCE interval | 15 s |
| periodic ANNOUNCE tick (one link per tick) | 1 s |
| `ann.sum` window | 60 s |
| challenge / proof payload / signed message | 16 B / 97 B / 73 B |
| key pin per verified node id | 10 min, 64 entries |
| proofs checked per link / proof sends per link / resend | 3 / 8 / once per 15 s until `pv=1` |
| same-device duplicate: address memory / refusal of redials | 30 s (60, 120, 300 s per repeat) |
| addresses / collapse keys remembered | 64 each |
| closes of one link key | 4 per 300 s |
| links of one node a send or flood goes to | 4 |
| idle time before a link may be evicted | 30 s |
| subscribed link without ANNOUNCE | closed after 35 s |
| evicted address: redial wait / incoming refusal | 30, 60, 120, 300 s / 60 s |
| ANNOUNCE max neighbours | 10 |
| outbox retry / give-up | 20 s / 1 h |
| unknown-sender refresh | once per 60 s |
| connect retry backoff first / max | 15 s / 300 s (plus or minus 20 %) |
| backoff identifiers remembered | 64 |
| discovery resume after Bluetooth call route ends | within 2 s |
| discovery restart rate limit on route flapping | once per 5 s |
