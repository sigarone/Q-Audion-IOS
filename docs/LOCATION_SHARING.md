# Location sharing in chat: platform behaviour

The wire contract is `WIRE_SPEC.md` section 14 and the known-answer vectors are `QAudionEngine/Tests/QAudionEngineTests/Resources/kat/location-kat.json`.
This document is everything that is not wire: how the platforms behave, what the user sees and the permissions. It is written to be identical on iOS and Android.

`MUST`, `MUST NOT`, `SHOULD` and `MAY` have their RFC 2119 meaning.

---

# Part 1. Platform contract (identical on iOS and Android)

## 1.1 Cadence, sampling and battery

Sampling (how often the phone asks the operating system for a position) and transmission (how often a frame leaves)
are separate things.

Transmission is FIXED by the wire contract (`WIRE_SPEC.md` 14.6.1): one frame every 30 seconds, every 60 seconds while
the platform is in a low-power mode (iOS Low Power Mode, Android battery saver). It never depends on movement or on
whether a new fix arrived, so that the relay learns nothing about whether the sender moves. A frame is sent on schedule
even when the position has not changed, and carries the newest fix with its `age`.

Sampling is ADAPTIVE, because it is what costs battery. It is a local matter and never visible to the server:

| Tier | Enter when | iOS `CLLocationManager` | Android `LocationRequestCompat` |
|---|---|---|---|
| Moving | a fix 50 m or more from the still anchor, or a speed of 1 m/s or more | `desiredAccuracy = kCLLocationAccuracyNearestTenMeters`, `distanceFilter = 10` | `QUALITY_HIGH_ACCURACY`, interval 5 s, minimum distance 10 m |
| Still | no displacement of 25 m or more for 3 minutes | `desiredAccuracy = kCLLocationAccuracyHundredMeters`, `distanceFilter = 50` | `QUALITY_BALANCED_POWER_ACCURACY`, interval 60 s, minimum distance 50 m |

iOS also sets `pausesLocationUpdatesAutomatically = false` (an automatic pause cannot be resumed from the background
under When In Use), `activityType = .other`, `allowsBackgroundLocationUpdates = true` only while a share is live, and
`showsBackgroundLocationIndicator = true`.

The tick that builds a frame does not wait for a fresh fix: it takes the newest one. When no fix has been obtained for a
long time (tunnel, indoors), frames keep carrying the last fix with a growing `age`.

Battery targets to verify on devices before the contract is frozen (targets, not measurements): the energy attributable
to a share is at most 5 % of the battery per hour while moving with the screen off, and at most 1.5 % per hour while
still, on a mid-range phone of each platform. The WebSocket is already kept alive during a share, so frames ride an open
socket; aligning the tick with the keepalive saves radio wake-ups and SHOULD be done. The fixed cadence is a privacy
property, not a tuning knob: if measurements miss the targets, the levers are the sampling tiers, not the cadence.

## 1.2 Push, wake and receiving when the app is not in the foreground

This feature adds no push of its own on any platform: no push is ever added for location.

- A pin and a live start are chat messages. Each gets exactly the wake that every chat message already has on the receiving
  platform: on Android the FCM wake of a chat message, on iOS none. Nothing is added to it and nothing is removed.
- A frame, a stop and a final frame never wake a device and never notify.

What the receiver sees follows from that:

| Receiver | What happens |
|---|---|
| iPhone, app in the foreground | the socket is open: the card updates live as frames arrive |
| iPhone, app suspended, not sharing | no frames arrive and nothing runs. When the app is used again the socket reconnects, the pending chat messages are replayed (a pin, a live start), and the card shows the last state it knows. The clock decides the rest: the card turns STALE after the interval of 3 frames (at least 120 s) and ENDED at its end time, with no position. A start that is replayed after its end time is created ended |
| iPhone that is itself sharing | its background location session keeps the process running and the socket open, so it keeps receiving the frames of the peer it follows while it shares |
| Android, app in the foreground | as the iPhone in the foreground |
| Android, app in the background | by default, as the suspended iPhone: it catches up when the app returns to the foreground or when a message wake has run the app. Optionally the user can ask to keep following, see below |

The cards say so: a live card always shows when the last update arrived ("aggiornata N min fa") and a clear ended state.

### Android: following a share while the app is in the background (MAY, opt-in)

Baseline (MUST): catching up on return, as above. Nothing else is required of an Android receiver.

Option (MAY): the user keeps following a share in the background. The platform-legal way to do it, and the only one this
contract allows:

- The foreground service type is `specialUse`, with `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` set to a neutral subtype
  (`live_follow`). The other types do not describe this work and MUST NOT be used for it: `location` is for apps that
  read the device's own location (the receiver does not), `dataSync` has a 6-hour timeout in 24 hours from Android 15 and
  a share lasts up to 24 hours, `remoteMessaging` is for handing a user's messages from one of their devices to another,
  `connectedDevice` is for external devices, and `shortService` is limited to a few minutes. `specialUse` needs the
  foreground-service declaration in the store console.
- It starts only from a user action that is visible to the platform: a tap on "Segui in background" on the live card, or
  on the action of the live-start notification. It never starts by itself from a received message, because Android 14
  and later refuse a foreground service started from the background without such an action.
- While it runs, a persistent notification shows "Stai seguendo la posizione di X" with an action "Smetti". The text never
  carries a position. If notifications are denied the service does not start (a foreground service without a visible
  notification is not allowed to stand in for the user's awareness), and the card says so.
- It holds the WebSocket only; it samples nothing and asks for no location permission. It ends at the end time of the
  last share it follows, on "Smetti", on logout and on a block of the peer, and it follows at most the shares of the
  conversations the user chose.
- If the platform refuses to start it, or the vendor kills it, the receiver falls back to the baseline silently: the card
  turns STALE and then ENDED by the clock.

## 1.3 Local storage and lifecycle

- Two stores. The message row holds a local form of the body; a separate live-share store holds the share state. iOS:
  GRDB migration `v10` with a `live_shares` table keyed by the start row's client message id. Android: Room schema 28,
  `MIGRATION_27_28`, table `location_shares`. Group messages hold pins only, which are small and never rewritten.
- The local form of a row never contains `k`. A pin row keeps its coordinates (they are the message, like a photo), sealed
  at rest like any body. A live row keeps `sid`, `st`, `du`, `endAt` and the state; the moving position lives only in the
  live-share store.
- Sender outbox: the full start body (with `k`) exists only in the outbox until the `msg_sent` echo; then the row is
  rewritten to the local form. The outbox copy is never used to seal a frame.
- Sender key and counter: the sender keeps the share key and the counter of the next frame in the memory of the process
  that runs the share, and nowhere else. A process that starts again never builds a frame for a share of the previous
  process, neither a position nor a final one: it sends the stop only (`WIRE_SPEC.md` 14.6.1 rules 9 and 10).
- One sealer per share: a single owner holds `k` and the counter of the next frame, and sealing a frame takes the counter
  and advances it in one serialized step. A reconnect that re-arms the tick timer without cancelling the old one, a second
  iPad scene or window with its own copy of the share, or a retry that builds a frame beside a tick would each seal one
  counter twice. `k` is never placed in anything the system can hand to another process or bring back after one: the
  extras of an Intent or a PendingIntent of a service that the system restarts (after process death a
  `START_REDELIVER_INTENT` service starts again at counter 1), saved instance state, iOS state restoration, WorkManager
  input data, a backup or a device migration. A copy of that kind never seals, and a service or a process that the system
  starts again is a restart: it sends the stop only (`WIRE_SPEC.md` 14.6.1 rules 9 and 10).
- Failed writes and a dropped socket: a frame is built only while the socket is up. A frame that was sealed has used its
  counter whether or not the write succeeded: the counter is never given back and the frame is never sealed again, with
  the same plaintext or a newer fix (writing the identical bytes again is fine). A client that counts a frame as "not
  sent" and seals the next one under the same counter reuses an AES-GCM nonce under the share key, which leaks the XOR
  of two positions and lets frames be forged (`WIRE_SPEC.md` 14.6.1 rules 5 and 9).
- Receiver state: the counter of the last frame and the time it arrived are written to the live-share store, durably,
  before a new position is shown. After a restart the card continues from them, and a share whose counter cannot be read
  back, or whose key cannot be loaded (a Keychain item or a Keystore key that is gone after a restore or a migration),
  ends as `state_lost`. The store keeps the client message id and the `sid` of every start, ended ones included (also
  after a clear, a delete for me and a logout, until `TOMBSTONE_KEEP` after the end): a start
  that repeats either is a duplicate and never overwrites or resets a record, so a replayed start cannot reopen a share
  with a counter of 0. A stop or a delete that arrives before its start is remembered for that conversation, for exactly
  87 000 seconds and the last 16 targets (`WIRE_SPEC.md` 14.7): after a stop the start appears as ended; after a delete
  it goes through the normal delete path and no live-share card is shown, as when the delete arrives after the start.
- A device that will not follow a live share (the own copy on another own device, the Desktop version 1, a start refused
  for its context, a notification extension) discards the share key at once and never stores the body that carries it.
- Backups and exports: the live-share store, `k` and live positions are excluded from backups, the data export, the
  transcript export and any sync. Pin rows follow the backup rule of text messages, with the label in exports instead of
  coordinates.
- Search: location rows are not indexed. The list preview, the Siri cache, the Enigma row mapper and the reply quote use
  the fixed labels.
- Disappearing messages. A pin follows the conversation timer like any message. A live row is EXEMPT from the timer while
  the share runs, so that it cannot vanish under an active share; when the share ends (any reason) the key and every
  position are deleted, the row stays as "Condivisione terminata", and the timer then starts: `expiresAt = end + timer`.
  View-once does not apply to a location.
- Delete: delete for me removes the row, the card, `k` and the positions of the live-share entry and keeps its client
  message id, `sid` and end time for `TOMBSTONE_KEEP` after the end (the duplicate test of `WIRE_SPEC.md` 14.6.2 step 1;
  the whole entry goes only with the deletion of the whole local store); on the sender it also ends the share. Delete for
  everyone (the existing `qa_ctl` delete) ends the share on both sides, and no live-share card is shown for it whichever
  order the delete and its start arrive in: a delete that arrives first is remembered and the start is then handed to the
  same delete path (the row removed or the deleted placeholder), never created as an ended card.
- Edit: refused for location rows (with a typed classifier, never a substring test of the body). An edit that arrives for a
  location row, or whose new body is a location message, is dropped without a trace.
- Forward: location rows cannot be forwarded. Copy is allowed.
- Copy: "Copia coordinate" on a pin and on an active live card copies `DEC7(lat), DEC7(lon)`. iOS sets the pasteboard
  local-only with a 2-minute expiration; Android marks the clip sensitive (`EXTRA_IS_SENSITIVE`, API 33 and later).
- What stays after a share ends: only the fact that a live share took place, its duration and its end. The last position
  is not kept.
- Every site that derives display text from a body MUST know the new kind, or it would show raw JSON with coordinates:
  list preview, notification text, share-sheet and Siri caches, search indexing, the export, backup and data-export
  writers, the reply quote, forward and edit guards, the group and mesh inbound paths, the car mapper and the Enigma
  mapper. A platform test MUST feed a location body through each site and assert that no digit of the coordinates appears
  in its output.

## 1.4 Privacy

- The position leaves the phone only when the user taps send or start, only to the chosen conversation, and only sealed.
  There is no "request someone's location" feature, by design.
- Minimal permission: When In Use on iOS, foreground location plus a location foreground service on Android, never the
  background-location permission (1.8).
- While a live share runs, the sender always sees that it runs and can stop it with one tap.
- No position in logs, telemetry, crash reports, notifications, car read-aloud, search indexes, previews, backups of live
  data, or file names.

### Logs and telemetry

The no-log rule and the redactor rules ship in the SAME release as the feature, on every platform, with their tests.

1. A no-log rule: location code logs only event names, reason codes, counters, duration presets, permission states and
   short row ids. Never `lat`, `lon`, `acc`, `age`, `sid`, `k`, a body, a `geo:` URI, a map link, a GPX path with content,
   or a frame. A unit test per platform runs a full share with a capturing log sink and asserts that no coordinate
   digits appear.
2. A coordinate rule in every redactor: iOS `LogRedactor` (both paths), its Python parity port and the log shipper
   script, Android `OtlpRedactor` and `OtlpLogTripwire` (a new finding type), the Desktop redactor. Shapes: a decimal pair
   `[-+]?\d{1,3}\.\d{3,}` followed by `,`, `;` or a space and another such number; `geo:` URIs; `ll=`, `q=`, `daddr=`,
   `destination=` with numeric pairs; key-value forms of `lat`, `lon`, `lng`, `latitude`, `longitude`, `acc`, `accuracy`
   with any number; E7 integers under those keys; a whole location body. The shared `redaction_cases` of the KAT pin the
   shapes; each platform asserts that the listed substrings do not survive, whatever placeholder it writes.
3. Telemetry is counters and enums only: `loc_pin_sent`, `loc_live_started{duration_preset}`, `loc_live_ended{reason}`,
   `loc_frames_sent`, `loc_frames_dropped{reason}`, `loc_permission{state}`, `loc_rejected{code}`. No accuracy values, no
   `age`, no times of day.
4. Server: counts only for `eph_relay`; the relay handler writes no log line and no log line of any path carries a
   payload (`WIRE_SPEC.md` 14.8).

### Indicators and stop controls (sender)

- System: iOS shows the blue location pill or arrow while the app uses location in the background (automatic for When In
  Use apps). Android shows the location foreground-service notification and the status-bar location icon.
- Android foreground-service notification: own channel `location_sharing`, low importance, ongoing, text "Condivisione
  della posizione attiva fino alle HH:MM", action "Interrompi". Its public version (lock screen) omits the contact name.
  If notifications are denied (Android 13 and later), the notification is hidden from the shade but still listed in the
  system task manager; the in-app strip is then the main indicator, and the app SHOULD ask for the notification
  permission before the first live share.
- In the conversation: a strip above the composer, "Stai condividendo la posizione fino alle HH:MM" with "Interrompi".
- Conversation list: a "Live" chip on the conversation while the user shares there.
- Settings, Privacy: "Posizione condivisa" lists active shares with "Interrompi tutte".
- Stop is one tap, no confirmation dialog.

### What happens when

| Situation | Sender | Receiver |
|---|---|---|
| The user taps Interrompi | `loc_stop` at once, the final frame on the next tick, wipe. Before the echo of the start: a start that has not left the device is withdrawn, otherwise the stop waits for the echo | ENDED (`stopped`) at once if online, otherwise when the stop arrives or at `endAt` |
| `st + du` reached (24 hours at most) | final frame and `loc_stop`, wipe, one quiet local notice | ENDED (`expired`) at `endAt` even if nothing arrives |
| App force-quit (iOS) or stopped from the task manager (Android 13 and later) | nothing can be sent; at the next process start the stale share is ended with `loc_stop` only (no frame of any kind: the key and the counter of the old process are gone) and the user is told | STALE, then ENDED at `endAt` or when the stop arrives |
| Location permission revoked | iOS: the authorization callback ends the share (final frame and stop). Android: the process is killed on revocation, handled at next start | as above |
| Location services off | ends the share | as above |
| Reboot or process death | the share is not resumed (Android cannot start a location foreground service from the background; iOS does not relaunch a When In Use app); the next start sends `loc_stop` only | as above |
| Network lost, socket down | no frame is built while the socket is down (the ticks are skipped, nothing is queued or sent over REST); the next tick after reconnection builds the next counter with the newest fix. A frame whose write failed has used its counter and is never sealed again. If the user stops while the socket is down, the `loc_stop` goes out through the durable path and no final frame is built | STALE after the interval of 3 frames (at least 120 s), ENDED at `endAt` or when the stop arrives |
| Peer blocked | ends the shares with that peer; the server also drops `eph_relay` between blocked users | the shares received from that peer end at once and their keys and positions are wiped; frames and stops from a blocked sender are dropped |
| Peer identity key changed | ends the shares with that peer | n/a |
| Conversation cleared, logout, wipe | ends and wipes | the shares end and `k`, the positions and the cards are wiped; the client message id and the `sid` of each start and the end time stay for `TOMBSTONE_KEEP` (87 000 s) after the end, so that a start redelivered after a clear is still a duplicate (`WIRE_SPEC.md` 14.6.2 step 1). Only the deletion of the whole local store (account deletion, a wipe of all app data, a logout that erases the database) takes the two ids with it |
| Flag `location_share.enabled` false | entry points hidden, active shares ended | entry points hidden; received cards still render |

### Other leaks closed

- No map tiles or snapshots in the bubble: a map preview from a platform map service sends the region to that service. The
  card shows a stylised pin drawn locally, with an "Apri" action.
- No reverse geocoding.
- GPX files are written to a dedicated cache folder (Android `FileProvider` path `qa-geo`; iOS a temporary directory),
  deleted when the share sheet closes and swept at every launch.
- Opening a position in another app is always a user action and hands the position to that app only.
- Android chat screens are already `FLAG_SECURE`; the card inherits it.

## 1.5 User interface

Entry points:

- 1:1 chat: a new "Posizione" action next to photos and files. It MUST NOT be gated by `Capability.files` /
  `Capability.FILES` (nothing is uploaded; location sharing is free): the photo and paperclip buttons are disabled
  together by that gate, so the location entry needs its own enablement.
- Group chat: pin only. Over a call: the 1:1 in-call chat gets the same entry.

Share sheet, "Condividi posizione":

1. "Invia la posizione attuale" with the live accuracy ("Precisione ±12 m"). On iOS this control is the system
   `LocationButton`, which grants a one-time authorization without a prior permission prompt. On Android a normal button
   that asks for the location permission at first use.
2. "Condividi la posizione in tempo reale" with the duration presets: "15 minuti", "1 ora", "8 ore", "24 ore"
   (`DU_PRESETS`). The format accepts any duration from 60 seconds to 24 hours, so the presets can change without a format
   change. Live sharing is offered in a 1:1 chat only.
3. Before the first live share ever: a short explainer, "La posizione è cifrata end-to-end: la vede solo [Nome], non il
   server. Puoi interrompere quando vuoi e si ferma da sola alla scadenza."
4. Precision follows what the system grants. When only approximate location is granted the sheet says "Posizione
   approssimativa" (`ap = 1`) and, on iOS, offers the temporary full-accuracy request. There is no manual "approximate"
   option.

Cards:

| Card | Sender sees | Receiver sees |
|---|---|---|
| Pin | "Posizione", accuracy, time | "Posizione", "±12 m", time of the fix; actions |
| Live, active | "Posizione in tempo reale · fino alle HH:MM", "Interrompi" | "Posizione in tempo reale · aggiornata 20 s fa · fino alle HH:MM"; actions on the latest position |
| Live, stale | same as active | "Ultimo aggiornamento N min fa" |
| Live, ended | "Condivisione terminata" | "Condivisione terminata", no position, no actions |
| Rejected | placeholder | "Posizione non leggibile. Aggiorna l'app." or "Impossibile mostrare la posizione." |

The card is drawn locally (a pin graphic, the accuracy, the times) and has an "Apri" action. Actions (1.6): Android
"Apri con…", "Condividi GPX", "Copia coordinate"; iOS "Apri in Mappe", "Apri in Google Maps", "Condividi GPX", "Copia
coordinate". Accessibility: one element, read as "Posizione condivisa, precisione 12 metri", actions exposed as custom
actions. Strings are added in Italian first and localised through the existing catalogs (iOS `Localizable.xcstrings` and
`InfoPlist.xcstrings` in it, en, es, fr, de, pt-BR; Android `values`, `-en`, `-de`, `-es`, `-fr`). Enigma reveals the card
as a whole, like a reply.

Code placement: iOS logic in `QAudionEngine` (codec, conversion, frame crypto, receiver state machine), the app a thin
layer; new helpers in `Services/*.swift` because `ChatDetailScreen.swift` is near the type-checker budget. Android logic
in `qaudion-engine` (codec, frame crypto, state machine) and `feature-chat` / `core-data` for wiring.

## 1.6 Opening a position in other apps

The exact text of every output is pinned by `open_cases` (`WIRE_SPEC.md` 14.9). Nothing is uploaded.

### iOS

- "Apri in Mappe": the Apple Maps link `https://maps.apple.com/?ll=<lat>,<lon>&q=<label>` opened with
  `UIApplication.open`. No map framework is linked for it and no map view is shown.
- "Apri in Google Maps": the universal link `https://www.google.com/maps/search/?api=1&query=<lat>%2C<lon>`. It opens the
  Google Maps application when it is installed and a web page otherwise.
- "Condividi GPX": the temporary-file share-sheet pattern. Any installed application that imports GPX appears in the
  sheet.
- No custom URL scheme is used anywhere, so `LSApplicationQueriesSchemes` stays absent. The two links are `https`.
- Directions and other navigators are the map applications' job: the app does not name them.

### Android

- "Apri con…": `Intent(ACTION_VIEW, geoUri)` wrapped in `Intent.createChooser`, so the system chooser lists every installed
  application that handles `geo:`; `ActivityNotFoundException` shows a message. To hide the action when nothing can handle
  `geo:`, the manifest gains
  `<queries><intent><action android:name="android.intent.action.VIEW"/><data android:scheme="geo"/></intent></queries>`.
- "Condividi GPX": the file through the existing `FileProvider` (`${applicationId}.fileprovider`, new `cache-path`
  `qa-geo` in `res/xml/file_paths.xml`), MIME `application/gpx+xml`, `ACTION_SEND` and `ACTION_VIEW` via the chooser,
  `FLAG_GRANT_READ_URI_PERMISSION`.
- The app declares no incoming intent filter for `geo:` or GPX.

### Desktop

Recognition, the placeholder rules, a pin card with "Copia coordinate" and "Salva GPX" (save dialog), and a live card that
says the share can be followed on the phone. Desktop ignores `eph_relay` in version 1 and applies `loc_stop` to its card
state.

## 1.7 Android Auto and CarPlay

### Android Auto

What the platform allows (androidx.car.app 1.7.0):

- `CarContext.ACTION_NAVIGATE` and `CarContext.startCarApp(Intent)` exist.
- `CarPendingIntent.getCarApp` accepts only: an intent for the app's own `CarAppService`; `ACTION_NAVIGATE` with a `geo:`
  URI that has a `lat,lng` part or a `q=` query; `DIAL` / `CALL` with `tel:`. An explicit component of another package
  throws `SecurityException`.
- The host sends `ACTION_NAVIGATE` to its default navigation application, the one the driver used most recently. The car
  therefore cannot offer an in-app list of navigation applications: the choice is the driver's default in the car. On the
  phone the `geo:` chooser lists all applications.
- `ConversationItem.Builder.addAction` allows exactly one custom action with a required icon, and
  `CarAppExtender.Builder.addAction(icon, title, PendingIntent)` exists for notifications.

Flow:

1. A pin or a live start arrives. The car mapper learns the new kind: the text handed to the host is a fixed label ("Ha
   condiviso una posizione", "Sta condividendo la posizione in tempo reale"), only when the existing gates allow bodies
   (hidden content and previews off give the generic label). The host reads the label aloud. Frames never cause a new
   heads-up or read-aloud.
2. After the message has been read (read aloud by the host, which marks it read, or opened in the Messages tab) the app
   offers the confirmation screen "Navigare verso la posizione?" (`MessageTemplate`, pattern of the existing dial
   confirmation): title "Posizione di [Nome]", text exactly "Navigare verso la posizione?" for a pin and for a live share,
   primary action "Naviga", second action "Annulla". It is reached from a notification
   action "Naviga" (whose `PendingIntent` targets the app's own `CarAppService` with a deep-link target
   `NAVIGATE_CONFIRM`, row id only, no position in the intent) and from the single custom action of the conversation item
   in the Messages tab, shown when the newest message of the conversation is a pin or an active live share.
3. "Naviga": `carContext.startCarApp(Intent(CarContext.ACTION_NAVIGATE, Uri.parse(geoUri)))`. The car's default
   navigation application opens with the destination. "Annulla" pops the screen.
4. Gates before showing the action or the screen: app unlocked and key vault available, bodies allowed, share not ended.
   When locked, the existing handoff screen asks to unlock on the phone.
5. One confirmation screen counts as one template step of the 5-step task quota.
6. A live share does not follow the moving position in the navigation application; the driver can repeat the action to
   navigate to the newest position.

Code, strings and comments MUST NOT name any navigation application: the car uses whichever one is its default.

To verify on the Desktop Head Unit and in a real car before freezing: whether the host renders a custom notification
action on a messaging notification (the documentation treats messaging notifications as reply and mark-as-read only);
whether the host's mark-as-read after reading aloud is a usable trigger; whether `startCarApp` with `ACTION_NAVIGATE`
works for an app whose categories are only CALLING and MESSAGING; behaviour with two navigation applications installed;
driving versus parked restrictions on the confirmation template. Fallback if the notification action is not rendered: the
Messages-tab action only.

### CarPlay

CarPlay is not available to the app (the scene is compiled out and the entitlement is not granted). With CarPlay,
messages are read by Siri from notifications; the fixed-label rule above ensures Siri never reads coordinates. The iOS
equivalent of the car flow is therefore the phone-side "Apri in Mappe", "Apri in Google Maps" and "Condividi GPX".

## 1.8 Permissions

| | iOS | Android |
|---|---|---|
| Pin | `LocationButton` one-time grant, or When In Use if already granted; `NSLocationWhenInUseUsageDescription` | `ACCESS_COARSE_LOCATION` and `ACCESS_FINE_LOCATION` requested together at first use; coarse-only handled and labelled |
| Live | When In Use requested at the first live share (Allow Once works for the session); `UIBackgroundModes` `location`; `allowsBackgroundLocationUpdates` only while sharing; updates started in the foreground | the same runtime permissions; `FOREGROUND_SERVICE_LOCATION`; a service with `android:foregroundServiceType="location"` started only from the visible chat (Android 14 and later throw otherwise); a one-time grant stays valid while the foreground service runs |
| Precise versus approximate | `NSLocationTemporaryUsageDescriptionDictionary` purpose key for the temporary full-accuracy request; reduced accuracy sets `ap = 1` | coarse-only sets `ap = 1` |
| Never requested | Always (`NSLocationAlwaysAndWhenInUseUsageDescription`) | `ACCESS_BACKGROUND_LOCATION` |
| Location API | `CLLocationManager` on every supported version (deployment target iOS 16) | platform `LocationManager` through `LocationManagerCompat` / `LocationRequestCompat` (androidx.core, already present), `FUSED_PROVIDER` on API 31 and later else GPS and network; no `play-services-location` |
| Denial | chat fully usable; the location entry explains how to enable it | the same |

The receiver-side foreground service of 1.2 (`specialUse`) is separate: it asks for no location permission.

The Android manifest comment that explains the removal of `ACCESS_FINE_LOCATION` must be rewritten, because the feature
is the real consumer it asked for.

## 1.9 Interactions with other features

- Groups: a pin works in a group; a live share is 1:1 only. Live in groups is a later version that needs a
  `group_eph_relay`, a per-share signing key announced in the start message (every member holds `k` and could otherwise
  forge the sharer's positions), a rule to end the share on membership or epoch change, and a member cap.
- BLE mesh: pins ride the mesh as any body; live starts never do; frames need the server.
- Multi-device: a live start is delivered per device like any message, and `eph_relay` reaches every connected device of
  the recipient; only the starting device sends frames; a `loc_stop` from any device of the sender account is valid.
- Blocked contacts: the existing block policy covers `loc_stop`; the server's contact-block gate covers `eph_relay`. A
  receiver that blocks the sender ends the shares it holds from that sender and wipes their keys and positions.
- Remote flag: `location_share.enabled` in the flags file is a kill switch (compiled default ON, the file can only turn it
  OFF). False hides the entry points and ends active shares; received cards still render. It is a client gate: the server
  relays regardless.
- Server offline queue: the pending replay drops 1:1 messages older than 24 hours, so a pin to a recipient offline for
  more than a day is lost like any message.
- Entitlements: free, outside `Capability.FILES`. Nothing is uploaded and messaging is never gated.

## 1.10 Platform tests and device tests

Platform behaviour tests (each repository): every display-text site with a location body (no coordinate digits in the
output); entry-point refusals; edit and forward refusals; the receiver state machine against `receiver_sequences`; the
storage split (no `k` in rows, backups, exports); the end triggers of `WIRE_SPEC.md` 14.6.1; the sender against
`sender_sequences` (a counter is never sealed twice: not after a restart, not after a failed write, no frame while the
socket is down; the stop after the echo; a step marked `"write":"fails"` is run by making the transport fail the write
of that step's frame, and `next_ctr` after it is compared); one sealer per share (a reconnect that re-arms the tick timer,
a second iPad scene or window, a retry beside a tick: no counter sealed twice); no `k` in the Intent or PendingIntent
extras of a restartable Android service (a redelivered Intent after process death builds no frame and sends the stop
only), in saved instance state, iOS state restoration, WorkManager input data, a backup or a migration; a state reload and a replay of an old frame against `receiver_sequences`; a
start redelivered under the same client message id or the same `sid`; a share whose key cannot be loaded; a stop that
arrives before its start, and a delete that arrives before its start; the user ids of the frame
aad taken from the server's strings and never rebuilt through a platform UUID type; an inbound edit on or into a location
row; notifications and car mapper labels; redaction and no-log tests; a blocked sender, and blocking a sender who has a live
share.

Device tests before the contract is frozen: iOS 16, 17 and 27 sender with the screen locked for 2 hours and the indicator
visible; Android 14, 15 and 17 sender with Doze, battery saver and one vendor with aggressive process management;
force-quit and task-manager stop; permission revoked mid-share; airplane mode for 10 minutes; receiver offline for 3 hours
then online; an iPhone that shares and receives at the same time; the Android background-following service on three
vendors; battery measurements against 1.1; Android Auto on the Desktop Head Unit and in a real car.

