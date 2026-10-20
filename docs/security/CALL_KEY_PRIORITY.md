# Call key priority

This document fixes how an app orders the pre-shared keys it holds, and therefore which key a call uses. It is the same in the iOS and Android repositories. It changes nothing on the wire: WIRE_SPEC.md section 3.3 already says the caller lists its keys by priority and the callee takes the first one it also holds. This document says how that priority is computed.

## 1. Groups

Every key belongs to one group, from its origin:

- H: a KMS key of class hw_only;
- K: any other KMS key;
- O: every other key (NFC tap, in-person pairing by QR and Bluetooth, anything else).

## 2. The list

The app keeps one ordered list of its keys, index 0 first. The caller's advert follows this list, for the OFFER, for the ACCEPT advert and for every re-key. The same list, with arrows to move a key up or down by one place, is shown in Key management on both apps. Keys that never take part in a call (device keys, call-derived message keys, identity keys) are not in the list.

Each key also carries one flag, "placed by hand", set when the user moves that key with an arrow (even when the move had no effect) and cleared only when the key is deleted. Only the moved key is marked, not the neighbour it swapped with.

## 3. A new key

- A new O key goes to the end of the list.
- A new H key goes right above the highest-ranked H or K key. If there is none, it goes above the first key not placed by hand (at the end when every key is placed by hand).
- A new K key goes right above the highest-ranked K key. If there is none, it goes right below the lowest-ranked H key. If there is no H key either, it goes above the first key not placed by hand (at the end when every key is placed by hand).

So by default the newest KMS key is first and the in-person keys are confirmations, and a key the user moved above the KMS keys keeps its place when a new KMS key arrives.

## 4. Moves and deletions

An arrow swaps the key with its neighbour above or below; moving the first key up or the last key down changes nothing. A deleted key leaves the list and loses its mark.

## 4a. Pairing again with the same device

An in-person key belongs to one device of the other person: it is bound to that device's identity key, and its method is NFC or in-person pairing (QR and Bluetooth). "The keys of a device" below means the keys bound to that identity key by that method. A new pairing with the same device by the same method replaces the earlier keys of that device in two steps, store and finalize, so that a lost message can never leave the two phones without a key in common. The same rule applies to both methods.

Store. A phone stores the new key only when its own user confirmed and it verified the other phone's confirmation. The new key takes the place in the list and the "placed by hand" mark of the highest-ranked key of that device. That key moves directly below the new key, without the mark, and every earlier key of the device is now "retiring". A retiring key is a live key: it is advertised and can be selected. When the device has no key yet, the new key is placed as in section 3. Storing deletes nothing.

Finalize. A phone finalizes the new key only when it knows the other phone holds it. Finalizing deletes every key of that device stored before the new one, and never a key stored after it. The evidence is one of:

- F1, a message of the pairing that the other phone sends only after it has stored the new key, verified under a key of that pairing. NFC v2 has two: the card's confirmation, which the reader verifies, and FINALIZE, which the card verifies (NFC_PAIRING_V2.md section 9).
- F2, a call with that device. A round of the call counts when its handshake signature verified under the identity key the new key is bound to and the peer's key confirmation MAC (WIRE_SPEC.md section 3.7.1, KCMAC) verified. In that round, either (a) the agreed PSK (WIRE_SPEC.md section 3.3, `selectedPskFingerprint`, resolved to the local key) is the new key, or (b) the peer's signed advertisement matched the new key through a v3 tag (WIRE_SPEC.md section 3.3.1); a match against the static fingerprint does not count.

Nothing else deletes a key of that device. Not a failed, rejected, cancelled or timed-out pairing, not a lost radio link, not a closed screen, not a timer. A stored key that never finalizes stays until the user deletes it. Key management shows it as waiting for the other phone, and warns before deletion that it may be the only key the other phone holds.

Which evidence each flow has today: in-person pairing by QR and Bluetooth v1 has F2 only, because its last CONFIRM can be lost. NFC v1 has F2 only. NFC v2 has F1 and F2.

A pairing with another device of the same person, or by the other method, is a new key (section 3). A key whose device identity is unknown is never replaced.

## 5. First run

When an app first builds the list from keys it already holds, it orders them H, then K, then O; inside H and inside K the newest first, inside O the oldest first. No key starts placed by hand.

## 6. Conformance

`call-key-priority-cases.tsv`, generated by `gen_key_priority_cases.py` and identical in both repositories, pins sections 3, 4 and 4a. Each row applies a sequence of operations to an empty list and gives the expected order. The operations are `+X` new key, `-X` delete, `^X` up, `vX` down, `~X>Y` Y stored as the replacement of X (X is the highest-ranked key of its device), and `!Y` Y finalized. The first letter of a name is its group. The rows include the loss sequences of in-person pairing: each row is the list of one phone. Both apps run every row through the same code that orders and prunes the real list.
