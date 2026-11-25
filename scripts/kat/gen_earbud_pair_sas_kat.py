#!/usr/bin/env python3
"""Reference vectors for the SAS words of an FE-5 earbud pairing (earbud-pair-sas-v1).

The two people who pair a couple of earbuds compare six words shown on their two phones before PAIR_FIN is
written. The earbud firmware has no word-form SAS for pairing (ee_pair.c only checks the SHA-256 transcript
hash of PAIR_FIN), so the words are a pure view of the 32-byte pair_id both phones derive:

  pair_id      = SHA-256("qa-earbud-excl-pair-v2" || eid_min || eid_max)       (unsigned lexicographic min/max)
  words        = for i in 0..5: WORDS[uint24_be(pair_id[3i .. 3i+3]) % 256]    (the first 18 bytes of pair_id)
  fingerprint  = the first 16 lower-case hex characters of pair_id (8 bytes), shown in groups of four

WORDS is the 256-entry PGP word list of the in-call SAS (PgpSasWordList.swift here, PgpSasWords.WORDS on Android):
the same list, in the same order, on both platforms; its SHA-256 over the words joined by "\\n" is pinned in the
file so a drifted list is caught by the vectors, not only by the words.

Independent implementation: hashlib only, the word list is parsed out of the Swift source (so the mapping is not
shared with the Swift code under test). Everything is derived from fixed bytes, so every run writes the same file.

Android reuses the file (EarbudPairTranscript.sasWords there): the vectors are byte-for-byte shared, and the tests of
both apps pin the SHA-256 of the file. Writes earbud-pair-sas-v1-kat.json next to this file, UTF-8, LF line endings.
"""

import hashlib
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
WORD_LIST_SWIFT = os.path.join(
    HERE, "..", "..", "QAudionEngine", "Sources", "QAudionEngine", "Crypto", "PgpSasWordList.swift")
EXCL_KAT = os.path.join(
    HERE, "..", "..", "QAudionEngine", "Tests", "QAudionEngineTests", "Integration", "Resources",
    "earbud-excl-v2-kat.json")
OUT = os.path.join(HERE, "earbud-pair-sas-v1-kat.json")

PAIR_LABEL = b"qa-earbud-excl-pair-v2"
WORD_COUNT = 6


def load_words():
    with open(WORD_LIST_SWIFT, encoding="utf-8") as f:
        text = f.read()
    start = text.index("public static let words")
    block = text[start:text.index("]\n}", start)]
    words = re.findall(r'"([^"]+)"', block)
    assert len(words) == 256, len(words)
    return words


def pair_id(eid_a, eid_b):
    lo, hi = (eid_a, eid_b) if eid_a < eid_b else (eid_b, eid_a)   # bytes compare unsigned-lexicographically
    return hashlib.sha256(PAIR_LABEL + lo + hi).digest()


def sas(words, pid):
    assert len(pid) == 32
    out = []
    for i in range(WORD_COUNT):
        n = (pid[3 * i] << 16) | (pid[3 * i + 1] << 8) | pid[3 * i + 2]
        out.append(words[n % len(words)])
    return out


def vector(words, name, note, pid, eids=None):
    v = {"name": name, "note": note}
    if eids is not None:
        v["eid_a_hex"] = eids[0].hex()
        v["eid_b_hex"] = eids[1].hex()
    v["pair_id_hex"] = pid.hex()
    v["words"] = sas(words, pid)
    v["fingerprint_hex16"] = pid.hex()[:16]
    v["fingerprint_display"] = " ".join(pid.hex()[i:i + 4] for i in range(0, 16, 4))
    return v


def main():
    words = load_words()
    eid_a = bytes(0x01 + i for i in range(32))
    eid_b = bytes(0x80 + i for i in range(32))
    eid_mitm = bytes(0x55 + i for i in range(32))

    vectors = []
    vectors.append(vector(
        words, "ascending_bytes",
        "pair_id 00 01 .. 1f: each 3-byte group maps to its last byte (02, 05, 08, 0b, 0e, 11); the vector the "
        "Android unit test pinned first",
        bytes(range(32))))
    vectors.append(vector(
        words, "descending_bytes",
        "pair_id ff fe .. e0: indices above 127, so a signed-byte mistake changes every word",
        bytes(0xFF - i for i in range(32))))
    vectors.append(vector(
        words, "honest_pair",
        "the two earbuds of the Android SAS test, in either order (the pair_id is symmetric)",
        pair_id(eid_a, eid_b), (eid_a, eid_b)))
    vectors.append(vector(
        words, "swapped_order",
        "the same two earbuds with eid_a and eid_b exchanged: the same pair_id, the same words",
        pair_id(eid_b, eid_a), (eid_b, eid_a)))
    vectors.append(vector(
        words, "substituted_identity",
        "a relay replaced earbud B by its own key towards one phone: the pair_id, and so the words, differ",
        pair_id(eid_a, eid_mitm), (eid_a, eid_mitm)))

    with open(EXCL_KAT, encoding="utf-8") as f:
        excl = json.load(f)
    for pw in excl["pairwise"]:
        ea = bytes.fromhex(pw["earbud_id_A_hex"])
        eb = bytes.fromhex(pw["earbud_id_B_hex"])
        pid = pair_id(ea, eb)
        assert pid.hex() == pw["pair_id_hex"], "pair_id disagrees with earbud-excl-v2-kat.json"
        vectors.append(vector(
            words, "excl_v2_kat_" + pw["name"],
            "the pair_id of earbud-excl-v2-kat.json pairwise[" + pw["name"] + "] (firmware, Android and iOS share it)",
            pid, (ea, eb)))

    doc = {
        "schema": "qa-earbud-pair-sas-v1-kat:1",
        "description": "SAS words and fingerprint of an FE-5 earbud pairing, derived from the 32-byte pair_id "
                       "(scripts/kat/gen_earbud_pair_sas_kat.py, hashlib only)",
        "word_count": WORD_COUNT,
        "word_list_sha256": hashlib.sha256("\n".join(words).encode("utf-8")).hexdigest(),
        "pair_id_label": PAIR_LABEL.decode("ascii"),
        "vectors": vectors,
    }
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("wrote %s (%d vectors)" % (OUT, len(vectors)))


if __name__ == "__main__":
    main()
