# BLE Mesh Offline Text Transport — iOS Port

> **Status:** WORK IN PROGRESS, branch `claude/ble-mesh-cleanroom-spike`.
> This is a **port** of an already-designed, already-built Android feature
> (`New-Q-Audion-Android`, same branch name, PR #25) — not a fresh design.
> Read `New-Q-Audion-Android/docs/ble-mesh/BLE_MESH_ARCHITECTURE_STUDY.md`
> first if you want the *why*; this document is the *where on iOS*.
> **Not hardware-validated.** CoreBluetooth has no reliable simulator either
> — the pure wire-format/policy layer is unit-tested (`swift test` /
> `engine-tests.yml`), the CoreBluetooth glue is only compiler-verified
> (`ios-ui-smoke.yml`), and the dual-role radio behavior itself needs two
> physical iPhones to actually confirm.

## 1. What this is

Same feature as Android: when two Q-Audion users have no network path, their
phones relay already-encrypted chat messages directly over Bluetooth LE,
flood-style, with a small "radar" UI inside the chat screen. Text only,
fallback-only, gated behind the same server flag key (`mesh_ble.enabled`)
both apps read — one flip turns it on for both platforms at once.

**Non-negotiable invariant, unchanged from Android:** the mesh layer is
ALWAYS an opaque envelope around ciphertext already produced by this app's
EXISTING message encryption (`QAudionEngine/Crypto/MessageCrypto.swift` and
the v2/v3/v4 dispatch in front of it — see §5). It never sees plaintext,
never invents a KDF/AEAD/handshake.

## 2. Concept -> iOS type/file map

| Android concept | iOS equivalent | File |
|---|---|---|
| `MeshNodeId` (8-byte id, hex) | `MeshNodeId` (`String`-backed, same hex canonicalization) | `QAudionEngine/Sources/QAudionEngine/Mesh/MeshNodeId.swift` |
| `MeshPacketType` (DATA/FRAGMENT/ANNOUNCE/ACK) | `MeshPacketType: UInt8` enum, same 4 cases | `.../Mesh/MeshPacket.swift` |
| `MeshPacket` (envelope: version/type/sender/recipient/ttl/sourceRoute/timestamp/payload) | `MeshPacket` struct, byte-identical wire layout (see file header) | `.../Mesh/MeshPacket.swift` |
| `MeshAnnounce` (cleartext discovery beacon) | `MeshAnnounce` (`Codable` -> JSON, same short field names `v/node/fp/hint/nbrs`) | `.../Mesh/MeshAnnounce.swift` |
| `MeshChatMessage` (ciphertext + AAD-reconstruction metadata) | `MeshChatMessage` (`Codable` -> JSON, same short field names `v/s/r/c/conv/ct/ts`) | `.../Mesh/MeshChatMessage.swift` |
| `MeshFragmenter` / `MeshFragmentReassembler` (packet-level FRAGMENT splitting) | `MeshFragmenter` / `MeshFragmentReassembler`, same threshold/caps/timeout constants | `.../Mesh/MeshFragment.swift` |
| `MeshRelayPolicy` (TTL + density-damped flood probability) | `MeshRelayPolicy`, same curve/constants | `.../Mesh/MeshRelayPolicy.swift` |
| `MeshTopology` (neighbor-graph BFS for a next-hop) | `MeshTopology`, same BFS-over-announced-neighbors shape | `.../Mesh/MeshTopology.swift` |
| `MeshRadioSchedule` (pure duty-cycle resolver) | `MeshRadioSchedule`, same priority-order `resolve(_:)` | `.../Mesh/MeshRadioSchedule.swift` |
| `MeshTransport` interface (dual central+peripheral role) | `MeshTransport` protocol + `MeshTransportDelegate` (delegate instead of `StateFlow` — see §4) | `.../Mesh/MeshTransport.swift` |
| `BleMeshTransportImpl` (real `BluetoothGattServer`/scanner/advertiser) | `BleMeshTransport` (real `CBCentralManager`+`CBPeripheralManager`) | `QAudionApp/Services/BleMeshTransport.swift` |
| `MeshFeature` (feature gate + node-id derivation) | `MeshFeature` (reads `FeatureFlags.bool("mesh_ble.enabled", false)` live, no separate `StateFlow` bridge needed — see §4) | `QAudionApp/Services/MeshFeature.swift` |
| `MeshService` + `MeshSendCoordinator` + `MeshReceiveCoordinator` (core-data orchestration split across 3 classes) | `MeshRuntime` (one class — no outbox/store-and-forward tier yet, see §6) | `QAudionApp/Services/MeshRuntime.swift` |
| `MeshRadar.kt` (Compose Canvas) | `MeshRadarView` (SwiftUI `Canvas`) | `QAudionApp/Views/Chat/Components/Mesh/MeshRadarView.swift` |
| `MeshBottomSheet.kt` (`ModalBottomSheet`) | `MeshSheetView` (`.sheet` + `.presentationDetents`) + `MeshTransportChip` | `.../Mesh/MeshSheetView.swift` |
| `MeshViewModel` (peer label resolution, chat-peer auto-highlight, tap-to-jump) | `MeshSheetViewModel` (same two behaviors, primitive-only init per §16) | `.../Mesh/MeshSheetViewModel.swift` |
| `MeshNodeIdentity` (node id <-> contact resolution) | Folded into `MeshFeature`/`MeshSheetViewModel` — see §5 for the key-source difference | — |
| `SendMessageUseCase`'s mesh branch | `ChatContainer.sendViaMesh`/`completeMeshSend`/`finishMeshSend` | `QAudionApp/Views/ChatContainer.swift` |
| `MeshInboundDispatcher` | `AppState.handleIncomingMeshMessage`/`attemptDecryptMeshWireBlob` | `QAudionApp/AppState.swift` |
| `Message.securityMetaJson: {"transport":"mesh"}` badge | `Message.viaMesh: Bool?` (own GRDB column + migration `v6-mesh-transport-tag`) | `QAudionEngine/Sources/QAudionEngine/Models/Message.swift`, `Persistence/QAudionDatabase.swift`, `Persistence/DatabaseMappers.swift` |
| Antenna icon in `ChatDetailScreen.kt`'s topbar | Antenna `Image(systemName: "dot.radiowaves.left.and.right")` button in `ChatDetailScreen.topBar`, gated `MeshFeature.enabled` | `QAudionApp/Views/Chat/ChatDetailScreen.swift` |

## 3. Module placement — mirrors Android's split, adapted to two targets

Android splits mesh across `qaudion-engine` (pure/framework code) and
`core-data` (orchestration) because that's where the existing WS transport
and crypto already live. iOS only has two comparable targets —
`QAudionEngine` (the SPM package: crypto, models, persistence, no
UIKit/CoreBluetooth) and `QAudionApp` (the app target: SwiftUI, services,
CoreBluetooth) — so the split lands exactly on that boundary:

- **`QAudionEngine/Sources/QAudionEngine/Mesh/`** — every pure type in the
  table above through `MeshTransport` (the protocol, not the
  implementation). No `CoreBluetooth`/`AppState`/`UIKit` import anywhere in
  this directory — verified by inspection, not just convention — so it
  compiles and runs on the bare `swift test` CI path with no Xcode
  toolchain, simulator, or hardware.
- **`QAudionApp/Services/`** — `BleMeshTransport` (the real CoreBluetooth
  glue), `MeshFeature` (the flag gate), `MeshRuntime` (the orchestration
  layer). Only verifiable by `xcodebuild`/CI (`ios-ui-smoke.yml`), never by
  `swift test`.
- **`QAudionApp/Views/Chat/Components/Mesh/`** — the SwiftUI surface.

## 4. `StateFlow` -> delegate, not Combine

Android's `MeshTransport` interface exposes `radioState`/`knownPeers`/
`incoming` as Kotlin `StateFlow`/`Flow`. Swift Package Manager code
(`QAudionEngine`) can depend on Combine without issue, but a delegate
protocol is the more idiomatic shape for a CoreBluetooth-adjacent Swift API
and keeps `Mesh/MeshTransport.swift` simpler — see that file's own doc for
the concurrency reasoning (`BleMeshTransport` runs its own dedicated
`DispatchQueue`, never main; `MeshTransportDelegate` conformers are
obligated to hop to `@MainActor` themselves).

Similarly, Android bridges the server-driven flag into a `StateFlow`
(`MeshFeatureGate`, a `core-data` singleton with its own `collectLatest`
loop) because `qaudion-engine` can't poll a server itself and something has
to own the reactive re-evaluation. iOS's `FeatureFlags` (existing,
`QAudionApp/Services/FeatureFlags.swift`) already owns polling/caching/
fail-safe-defaults and is a cheap synchronous in-memory lookup, so
`MeshFeature.enabled` just reads it live on every call — no separate
gate/bridge class needed.

## 5. Node identity — a real adaptation, not a 1:1 copy

Android derives a mesh node id from `ContactEntity.identityKeyEd25519PubB64`
— a raw Ed25519 public key cached per contact, populated by contact sync.
**iOS's contact model doesn't have that exact field.** The closest iOS
analogue, confirmed by reading `ContactsStore.swift` directly (not assumed):
`ContactsStore.StoredContact.pubkey: Data?` — "Long-term identity public
key, when known. Populated by the QR-scan pairing flow ... and by future
discover-v2 results." `MeshNodeId.from(identityKeyRaw:)`'s derivation
(SHA-256 truncated to 8 bytes) is format-agnostic, so it works unchanged
against whatever raw bytes `pubkey` holds.

**Since closed:** the LOCAL device's own long-term identity key is now
wired into `MeshRuntime.configureLocalIdentity(identityKeyRaw:)` from
`AppState.initialize()`, using `SovereignIdentityManager().loadIdentity()?.signingPublic`
— the same Ed25519 public key the KMS bundle publishes as `ed25519Pub`, so
the id a peer derives from the directory matches the id this device
advertises. Before this was wired, `MeshRuntime` fell back to
`MeshNodeId.random()` for the LOCAL node id on every launch, so this
device advertised a different id each time and could never be resolved by
a peer computing the id from its known identity key — the cross-platform
half of R1 (see `AppState.swift`'s `configureLocalIdentity` call site for
the full story). Resolving OTHER peers' node ids against their
`ContactsStore.pubkey` (the radar auto-highlight / tap-to-jump feature)
was always fully wired and never depended on this.

## 6. Store-and-forward: `MeshOutboxStore` / `MeshOutboxDrain`

Android's real integration surface (per its own architecture study, §3.2)
reuses its generic outbox: extending `PendingSendOrchestrator`'s
`KIND_MESSAGE`-only drain loop into a kind-dispatch table, with a new
`KIND_BLE_MESH` `PendingSendEntity` row and its own backoff schedule. iOS
has no directly equivalent generic outbox to extend (its retry/backoff
live inline per-transport, e.g. `ChatMessageSendService`), so rather than
force a shared table this got a small, self-contained pair of types
instead: `MeshOutboxStore` (`Services/MeshOutboxStore.swift`) is a plain
Codable array under one `UserDefaults` key — the same persistence style
`ConversationStore` itself used before message history moved to GRDB —
holding `MeshPendingSend` rows (message id, target node hex, the already-
sealed `MeshSealedShell` bytes, creation time, attempt count).
`MeshOutboxDrain` (`Services/MeshOutboxDrain.swift`) retries a row once its
target reappears in `MeshRuntime.peers` (triggered from
`MeshRuntime.applyKnownPeers`) and on a 20s backstop timer while the
antenna is on, and gives up past `MeshOutboxStore.maxAgeMs` (~1h, same
order of magnitude as Android's `MAX_MESH_ATTEMPTS` ceiling) — marking the
message `.failed` only then, not on the first failed write.
`ChatContainer.finishMeshSend`'s failure branch enqueues instead of
calling `markFailed` directly; the message simply stays in the `.sending`
status it already had.

This was flagged as the single largest functional gap versus Android's
store-and-forward design — closed, without adopting Android's shared-table
shape, since iOS never had the generic outbox that shape depends on.

## 7. Crypto decrypt-path duplication — a known, deliberate near-term risk

`ChatMessageSendService.encryptForWire` is a genuine, compiler-verifiable-in-CI
refactor: the multi-format encrypt dispatch (v4 native ratchet -> v3.1
ratchet -> legacy PSK-AEAD) was extracted out of `sendEncrypted` into its own
method, and `sendEncrypted` now calls it — ONE implementation, two callers
(WS send, mesh send).

The RECEIVE side (`AppState.attemptDecryptMeshWireBlob`) could not be given
the same treatment safely: `AppState.handleIncomingMessage`'s decrypt
dispatch is ~150 lines embedded in a ~7000-line file, with no local Xcode
toolchain available in this environment to verify a refactor against real
compiler feedback (see CLAUDE.md §16's own account of how silently this
file breaks). `attemptDecryptMeshWireBlob` is therefore a careful,
behavior-preserving DUPLICATE of that dispatch logic rather than a shared
extraction — same PSK-candidate walk, same v4/v3/v2/v1 routing, same helper
methods (`ratchetDecryptV3`, `ratchetDecryptV4`, `MessageCryptoV2.decrypt`,
`crypto.decrypt`). A follow-up PR, once it can be built and tested against
real CI feedback, should collapse both into one shared
`decryptInboundWire(cipher:senderId:clientMsgId:)` method.

## 8. Radio duty-cycle — iOS gives less control than Android

`MeshRadioSchedule.resolve(_:)` is ported byte-for-byte (same six profiles,
same priority order, same constants) and is fully unit-tested. But
`BleMeshTransport.updateSchedule(_:)` is currently a no-op: CoreBluetooth's
public scan/advertise APIs expose far less duty-cycle control than
Android's (no programmatic TX power, no scan window/interval — only a
"low duty cycle" advertise hint and
`CBCentralManagerScanOptionAllowDuplicatesKey`). The cadence is fixed once
`start()` is called, same simplification the Android sibling's own
`BleMeshTransportImpl.updateSchedule` first increment makes.

## 9. Send/receive integration — the exact wiring

**Send** (`ChatContainer.swift`): `sendMessage()` checks
`MeshRuntime.shared.activeTarget(for: conversationId.uuidString)` before
falling through to the normal WS path. If a target is selected,
`sendViaMesh` calls `ChatMessageSendService.encryptForWire` for the
ciphertext, wraps it in a `MeshChatMessage` envelope (cleartext routing
metadata + the ciphertext, exactly like the WS wire), and hands the
JSON-encoded envelope to `MeshRuntime.sendData(toNodeHex:payload:)`.

**Receive** (`AppState.swift`): `initialize()` assigns
`MeshRuntime.shared.onInboundData` to a closure that calls
`handleIncomingMeshMessage(fromNodeHex:payload:)`. That method decodes the
`MeshChatMessage` envelope, checks it's actually addressed to
`currentUserId`, dedups by `clientMsgId` via
`ConversationStore.findByClientMsgId`, decrypts via
`attemptDecryptMeshWireBlob` (§7), and persists a normal inbound `Message`
row tagged `viaMesh: true` — same find-or-create-conversation shape
`handleIncomingMessage` already uses for the WS path. Scoped to the CORE
text-message case only: a mesh-delivered `qa_ctl`/`qa_grp` control envelope
renders as plain (decrypted) text rather than being routed to
delete/edit/reaction/group-chat handling — an honest, if unpolished,
fallback rather than a silent drop.

## 10. Feature-flag gate

Single call site: `MeshFeature.enabled` (`FeatureFlags.bool("mesh_ble.enabled",
false)`, live-read, no caching of its own). Every mesh-touching surface
checks it:
- `ChatDetailScreen.topBar` — the antenna button doesn't render at all when off.
- `MeshRuntime.setAntenna(on:)` — refuses to start the radio even if called
  directly, so a stray call can never bypass the gate.
- `MeshSheetView.handleAntennaToggle` — surfaces a toast instead of toggling
  when off (defense in depth; the entry point is already hidden by the
  first check).

Bluetooth is NEVER touched just because the flag is on — only when the user
explicitly flips the antenna toggle inside the sheet, which itself requires
navigating to the sheet via the (flag-gated) antenna button. `CBCentralManager`/
`CBPeripheralManager` are constructed lazily inside `BleMeshTransport`/
`MeshRuntime.setAntenna`, never at app launch.

## 11. What's NOT done in this increment

- Shared (non-duplicated) decrypt dispatch (§7).
- Packet-level `.fragment` type is implemented and unit-tested
  (`MeshFragmenter`/`MeshFragmentReassembler`) but NOT wired into the send
  path — `BleMeshTransport` does its own separate link-layer chunking
  (a 4-byte `setId|index|total` frame header, matching the Android
  sibling's `BleMeshTransportImpl` byte-for-byte) which already handles any
  packet up to `MeshPacket.maxPayloadBytes` (16KB), so the packet-level
  FRAGMENT type is unused for now — this matches the Android sibling's own
  actual wired state (present, tested, integrated nowhere yet), not a gap
  introduced by this port.
- Export-compliance review for the new BLE-based P2P distribution path
  (same open item Android's own study flags in its §4 — unreviewed on
  either platform).
- Physical-hardware validation. Everything CoreBluetooth-specific in
  `BleMeshTransport` is unverified beyond compiling — pacing, write-type
  congestion handling (`peripheralManagerIsReady(toUpdateSubscribers:)`
  retry), and real multi-hop relay behavior all need two-plus real iPhones.
