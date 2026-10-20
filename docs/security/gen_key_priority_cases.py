#!/usr/bin/env python3
"""Builds call-key-priority-cases.tsv, the conformance table of docs/security/CALL_KEY_PRIORITY.md.

Usage: python3 gen_key_priority_cases.py out.tsv

Keys are named by group and number: H = KMS key of class hw_only, K = shared KMS key,
O = any other key (NFC, in-person QR + Bluetooth, anything else). A name such as K2 is
one key; the digit only tells keys apart.

Operations, applied in order to the list (index 0 = highest priority = first in the
caller's advert):
  +X    a new key X arrives (import / delivery / pairing with a device not seen before)
  -X    key X is deleted (by the user)
  ^X    the user moves X up by one place (no effect when already first)
  vX    the user moves X down by one place (no effect when already last)
  ~X>Y  section 4a "store": Y, from a new confirmed pairing with the device of X by the
        same method, is stored as the replacement of X. X must be the highest-ranked key
        of that device. Y takes X's place and mark; X moves directly below Y, without the
        mark. Nothing is deleted.
  !Y    section 4a "finalize": every key of Y's device stored before Y is deleted. A key
        of that device stored after Y is kept. Finalizing twice changes nothing.

A key the user has moved (^ or v, even when the move had no effect) is "placed by hand"
and stays placed until it is deleted, or until a replacement takes its mark (~). Only the
moved key is marked, not the neighbour it swapped with. The mark matters in one case: when
a KMS key arrives and no KMS key exists, it goes above the first key NOT placed by hand,
instead of at the very top.

Each row is the list of ONE phone. The loss rows give, for a re-pairing in which a message
was lost, what each phone's list looks like afterwards (one row per phone).
"""
import sys


def group(name):
    return name[0]


def first_not_placed(order, placed):
    for i, k in enumerate(order):
        if k not in placed:
            return i
    return len(order)


def insert(order, key, placed):
    g = group(key)
    if g == "O":
        return order + [key]
    hk = [i for i, k in enumerate(order) if group(k) in ("H", "K")]
    if g == "H":
        pos = hk[0] if hk else first_not_placed(order, placed)
        return order[:pos] + [key] + order[pos:]
    ks = [i for i, k in enumerate(order) if group(k) == "K"]
    if ks:
        pos = ks[0]
    else:
        hs = [i for i, k in enumerate(order) if group(k) == "H"]
        pos = hs[-1] + 1 if hs else first_not_placed(order, placed)
    return order[:pos] + [key] + order[pos:]


def apply(ops):
    order, placed = [], set()
    device, seq = {}, {}  # key -> device id, key -> store sequence number
    counter = 0
    for op in ops.split():
        kind, rest = op[0], op[1:]
        if kind == "+":
            key = rest
            assert key not in order, op
            order = insert(order, key, placed)
            counter += 1
            device[key], seq[key] = key, counter
        elif kind == "-":
            key = rest
            assert key in order, op
            order = [k for k in order if k != key]
            placed.discard(key)
        elif kind == "^":
            key = rest
            placed.add(key)
            i = order.index(key)
            if i > 0:
                order[i - 1], order[i] = order[i], order[i - 1]
        elif kind == "v":
            key = rest
            placed.add(key)
            i = order.index(key)
            if i < len(order) - 1:
                order[i + 1], order[i] = order[i], order[i + 1]
        elif kind == "~":
            old, new = rest.split(">")
            assert old in order and new not in order, op
            assert group(old) == "O" and group(new) == "O", op
            same = [k for k in order if device[k] == device[old]]
            assert same[0] == old, op + ": X must be the highest-ranked key of its device"
            i = order.index(old)
            order = order[:i] + [new] + order[i:]
            if old in placed:
                placed.discard(old)
                placed.add(new)
            counter += 1
            device[new], seq[new] = device[old], counter
        elif kind == "!":
            key = rest
            assert key in order, op
            order = [k for k in order if not (device[k] == device[key] and seq[k] < seq[key])]
            placed &= set(order)
        else:
            raise ValueError(op)
    return order


CASES = [
    ("nfc_then_kms", "an NFC key first, a KMS key delivered later: KMS goes first", "+O1 +K1"),
    ("kms_then_nfc", "KMS first, NFC later: KMS stays first", "+K1 +O1"),
    ("two_kms", "a newer KMS key goes above the older one", "+K1 +O1 +K2"),
    ("manual_nfc_first", "the user moves NFC above KMS", "+O1 +K1 ^O1"),
    ("manual_choice_survives_new_kms", "after the move, a new KMS key goes above the old KMS key but stays below NFC", "+O1 +K1 ^O1 +K2"),
    ("manual_choice_survives_new_hw", "after the move, a new hw_only key also stays below NFC", "+O1 +K1 ^O1 +H1"),
    ("hw_above_shared", "hw_only keys go above shared KMS keys", "+K1 +H1 +K2"),
    ("shared_below_hw", "a shared KMS key with only hw_only keys present goes right below them", "+H1 +H2 +O1 +K1"),
    ("no_kms_others_in_arrival_order", "without KMS, other keys keep their arrival order", "+O1 +O2 +O3"),
    ("kms_after_others", "a first KMS key goes to the top when no KMS key exists", "+O1 +O2 +K1"),
    ("move_down_kms", "the user moves the KMS key down below NFC", "+K1 +O1 vK1"),
    ("move_at_edges", "moving the first key up or the last key down changes nothing", "+K1 +O1 ^K1 vO1"),
    ("delete_top_kms", "deleting the top KMS key: the next KMS key does not jump over NFC", "+O1 +K1 +K2 ^O1 ^O1 -K2"),
    ("delete_then_new_kms", "NFC placed by hand above KMS; after deleting every KMS key a new KMS key still goes below NFC", "+O1 +K1 ^O1 -K1 +K2"),
    ("delete_then_new_kms_not_placed", "nothing placed by hand: after deleting every KMS key a new KMS key goes to the top", "+O1 +K1 -K1 +K2"),
    ("placed_mark_is_per_key", "only the moved key is placed: a new KMS key goes above the first key not placed by hand", "+O1 +O2 +K1 -K1 ^O2 +K2"),
    ("placed_mark_cleared_on_delete", "deleting a placed key clears its mark", "+O1 +K1 ^O1 -O1 +O1 -K1 +K2"),
    ("other_device_is_new", "a pairing with another device of the same person is a new key at the end", "+K1 +O1 ^O1 +O2"),
    ("mixed_sequence", "a longer mixed sequence", "+O1 +K1 +O2 ^O2 ^O2 +K2 +H1 vH1 -O1 +K3"),
    # Section 4a: store, then finalize.
    ("pair_again_store_default_place", "store: the new key takes the earlier key's place below KMS, the earlier key goes directly below it", "+K1 +O1 ~O1>O2"),
    ("pair_again_store_keeps_place", "store: the new key takes the place above KMS, the earlier key goes directly below it", "+O1 +K1 ^O1 ~O1>O2"),
    ("pair_again_store_moves_mark", "store moves the mark: a new KMS key then goes below the new key but above the unmarked earlier key", "+O1 +K1 -K1 ^O1 ~O1>O2 +K2"),
    ("pair_again_finalize", "finalize deletes the earlier key: the new key keeps the place and mark", "+O1 +K1 ^O1 ~O1>O2 !O2 +K2"),
    ("pair_again_finalize_default_place", "finalize with the default place below KMS", "+K1 +O1 ~O1>O2 !O2"),
    ("finalize_twice", "finalizing twice changes nothing", "+K1 +O1 ~O1>O2 !O2 !O2"),
    ("finalize_keeps_later_key", "finalizing a key never deletes a key of the same device stored after it", "+K1 +O1 ~O1>O2 ~O2>O3 !O2"),
    ("finalize_newest_deletes_all_older", "finalizing the newest key deletes every older key of the device", "+K1 +O1 ~O1>O2 ~O2>O3 !O3"),
    ("finalize_other_device_untouched", "finalizing touches only the keys of that device", "+O1 +O2 ~O1>O3 !O3"),
    ("user_deletes_waiting_key", "the user deletes a stored key that never finalized: the earlier key stays", "+K1 +O1 ~O1>O2 -O2"),
    ("user_deletes_retiring_key", "the user deletes the retiring key, then the new key finalizes", "+O1 ~O1>O2 -O1 !O2"),
    # Loss sequences, one row per phone; every phone starts with K1 (KMS) and O1 (in-person key of the other phone).
    ("loss_none_reader", "NFC v2, nothing lost, reader: stores and finalizes on the card's confirmation", "+K1 +O1 ~O1>O2 !O2"),
    ("loss_none_card", "NFC v2, nothing lost, card: stores, then finalizes on FINALIZE", "+K1 +O1 ~O1>O2 !O2"),
    ("loss_finalize_reader", "NFC v2, FINALIZE lost, reader", "+K1 +O1 ~O1>O2 !O2"),
    ("loss_finalize_card_before_call", "NFC v2, FINALIZE lost, card before any call: O1 retiring stays live", "+K1 +O1 ~O1>O2"),
    ("loss_finalize_card_after_call", "NFC v2, FINALIZE lost, card after a call that proved O2 (F2)", "+K1 +O1 ~O1>O2 !O2"),
    ("loss_confirm_reader", "NFC v2, card's confirmation lost, no re-tap, reader: nothing stored, O1 is the common key", "+K1 +O1"),
    ("loss_confirm_card", "NFC v2, card's confirmation lost, no re-tap, card: O2 waits and is never selected", "+K1 +O1 ~O1>O2"),
    ("loss_two_ceremonies_reader", "NFC v2, FINALIZE of ceremony 1 lost, confirmation of ceremony 2 lost, a call, a re-tap answered 03, reader", "+K1 +O1 ~O1>O2 !O2"),
    ("loss_two_ceremonies_card", "same, card: the call finalizes O2 and deletes only O1, the ceremony-2 key O3 stays", "+K1 +O1 ~O1>O2 ~O2>O3 !O2"),
    ("loss_role_swap_reader", "Android to Android: a phone holding a waiting key from an earlier ceremony as card is now the reader and finalizes the new key", "+K1 +O1 ~O1>O2 ~O2>O3 !O3"),
    ("loss_proximity_completed_side", "QR + Bluetooth v1, last CONFIRM lost, the side that completed: O2 stored, waits for a call (F2 only)", "+K1 +O1 ~O1>O2"),
    ("loss_proximity_other_side", "QR + Bluetooth v1, last CONFIRM lost, the other side: nothing stored, O1 is the common key", "+K1 +O1"),
    ("loss_proximity_both_completed_after_call", "QR + Bluetooth v1, both completed, after the first call that proved O2", "+K1 +O1 ~O1>O2 !O2"),
]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    names = [c[0] for c in CASES]
    assert len(names) == len(set(names))
    lines = ["# call-key-priority-cases.tsv: docs/security/CALL_KEY_PRIORITY.md. Generated by gen_key_priority_cases.py; do not edit.",
             "name\toperations\texpected_order\tdescription"]
    for name, desc, ops in CASES:
        lines.append("\t".join([name, ops, " ".join(apply(ops)), desc]))
    with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
