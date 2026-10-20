#!/usr/bin/env python3
"""Reference vectors for NFC pairing v2 (NFC_PAIRING_V2.md).

Independent implementation of the key schedule, the APDU encodings, the
commitment, the identity proofs, the SAS and the confirmation tags, written
with hashlib/hmac for SHA-256, HMAC and HKDF and the `cryptography` package
for X25519, Ed25519 (RFC 8032, deterministic) and AES-256-GCM.

Everything is derived from fixed seeds, so every run writes the same bytes.
ML-KEM-1024: the reader's key pair is a real key pair from a fixed 64-byte
FIPS 203 seed (d || z), so the encapsulation key passes the FIPS 203 input
check. Encapsulation is randomized and cannot be pinned, so the ciphertext is
fixed bytes and the shared secret is what FIPS 203 decapsulation returns for
it (the implicit-rejection value, deterministic for a given key and
ciphertext). A reader implementation can check its decapsulation against it;
a card implementation cannot reproduce the ciphertext and takes ct and ss as
given. X25519 and Ed25519 keys are real keys from fixed private bytes, so the
shared secret and the signatures in the vectors are genuine and verify.

Signatures: Ed25519 here is deterministic (RFC 8032). An implementation whose
signer is randomized (CryptoKit on Apple platforms) must check that the vector
signatures VERIFY and that its own signatures verify, not that its signatures
equal these bytes. Signatures are not part of any transcript hash, so the SAS,
the PSK and the confirmation tags do not depend on them.

Writes nfc-pairing-kat.json next to this file, UTF-8, LF line endings.
"""

import hashlib
import hmac
import json
import os
import struct

from cryptography.exceptions import InvalidSignature, InvalidTag
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.asymmetric.mlkem import MLKEM1024PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

VERSION = 0x02
AID = bytes.fromhex("F0BCF1073A5100")
CLA = 0x80
INS = {
    "EK_PUT": 0x30,
    "HELLO": 0x31,
    "CT_GET": 0x32,
    "AUTH_C": 0x33,
    "REVEAL": 0x34,
    "CONFIRM": 0x35,
    "FINALIZE": 0x36,
}
SW_OK = bytes.fromhex("9000")
EK_LEN = 1568
CT_LEN = 1568
CHUNK = 224
CHUNKS = 7
assert CHUNK * CHUNKS == EK_LEN == CT_LEN
USER_ID_MAX = 64
ZERO_NONCE = bytes(12)

L = {
    "th1": b"qaudion-nfc-v2/transcript",
    "commit": b"qaudion-nfc-v2/commit",
    "th_c": b"qaudion-nfc-v2/transcript-card",
    "th_r": b"qaudion-nfc-v2/transcript-reader",
    "enc_c": b"qaudion-nfc-v2/enc-card",
    "enc_r": b"qaudion-nfc-v2/enc-reader",
    "mac_c": b"qaudion-nfc-v2/mac-card",
    "mac_r": b"qaudion-nfc-v2/mac-reader",
    "sig_c": b"qaudion-nfc-v2/sig-card",
    "sig_r": b"qaudion-nfc-v2/sig-reader",
    "confirm_c": b"qaudion-nfc-v2/confirm-card",
    "confirm_r": b"qaudion-nfc-v2/confirm-reader",
    "sas": b"qaudion-nfc-v2/sas",
    "psk": b"qaudion-nfc-v2/psk",
    "confirmed": b"qaudion-nfc-v2/user-confirmed",
    "rejected": b"qaudion-nfc-v2/user-rejected",
    "final": b"qaudion-nfc-v2/finalize",
    "log": b"qaudion-nfc-v2/log",
}

DECISION_CONFIRM, DECISION_REJECT = 0x01, 0x02
STATE_PENDING, STATE_CONFIRMED, STATE_REJECTED, STATE_NONE, STATE_ABORTED = 0x00, 0x01, 0x02, 0x03, 0x04

USER_ID_ALPHABET = set(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

# The 8 small-order Ed25519 encodings (same table as SasComputation.kt / NfcSasComputation.swift).
SMALL_ORDER = [
    bytes.fromhex(h)
    for h in (
        "0100000000000000000000000000000000000000000000000000000000000000",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000080",
        "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
        "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
        "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac0374",
        "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03f4",
    )
]


# ---------------------------------------------------------------- Ed25519 point checks (section 3)

ED_P = 2**255 - 19
ED_L = 2**252 + 27742317777372353535851937790883648493
ED_D = (-121665 * pow(121666, ED_P - 2, ED_P)) % ED_P
ED_I = pow(2, (ED_P - 1) // 4, ED_P)


def ed_decode(b: bytes):
    """Strict RFC 8032 decoding. Returns (x, y) or None when not canonical / not on the curve."""
    if len(b) != 32:
        return None
    v = int.from_bytes(b, "little")
    sign, y = v >> 255, v & ((1 << 255) - 1)
    if y >= ED_P:
        return None  # non-canonical y
    x2 = (y * y - 1) * pow(ED_D * y * y + 1, ED_P - 2, ED_P) % ED_P
    x = pow(x2, (ED_P + 3) // 8, ED_P)
    if (x * x - x2) % ED_P != 0:
        x = x * ED_I % ED_P
    if (x * x - x2) % ED_P != 0:
        return None  # not on the curve
    if x == 0 and sign == 1:
        return None  # non-canonical sign of x = 0
    if x & 1 != sign:
        x = ED_P - x
    return (x, y)


def ed_encode(pt) -> bytes:
    x, y = pt
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def ed_add(a, b):
    (x1, y1), (x2, y2) = a, b
    t = ED_D * x1 * x2 * y1 * y2 % ED_P
    x3 = (x1 * y2 + x2 * y1) * pow(1 + t, ED_P - 2, ED_P) % ED_P
    y3 = (y1 * y2 + x1 * x2) * pow(1 - t, ED_P - 2, ED_P) % ED_P
    return (x3, y3)


def ed_mul(k: int, pt):
    r, q = (0, 1), pt
    while k:
        if k & 1:
            r = ed_add(r, q)
        q = ed_add(q, q)
        k >>= 1
    return r


def ed_identity_key_ok(b: bytes) -> bool:
    """Canonical encoding of a point in the prime-order subgroup ([l]A = O)."""
    pt = ed_decode(b)
    return pt is not None and ed_mul(ED_L, pt) == (0, 1)


# ---------------------------------------------------------------- primitives


def sha256(b: bytes) -> bytes:
    return hashlib.sha256(b).digest()


def hmac256(key: bytes, msg: bytes) -> bytes:
    return hmac.new(key, msg, hashlib.sha256).digest()


def hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    return hmac256(salt, ikm)


def hkdf_expand(prk: bytes, info: bytes, length: int) -> bytes:
    out, t, i = b"", b"", 1
    while len(out) < length:
        t = hmac256(prk, t + info + bytes([i]))
        out += t
        i += 1
    return out[:length]


def lp32(b: bytes) -> bytes:
    return struct.pack(">I", len(b)) + b


def det(label: str, n: int) -> bytes:
    """Deterministic test bytes: SHA-256 counter expansion of a label."""
    out, c = b"", 0
    while len(out) < n:
        out += sha256(b"qaudion-nfc-v2-kat/" + label.encode() + struct.pack(">I", c))
        c += 1
    return out[:n]


def ed_pub(sk: Ed25519PrivateKey) -> bytes:
    return sk.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)


def x_pub(sk: X25519PrivateKey) -> bytes:
    return sk.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)


def x25519(sk: X25519PrivateKey, peer_pub: bytes) -> bytes:
    """X25519 with the all-zero check; returns None for an all-zero result."""
    try:
        ss = sk.exchange(X25519PublicKey.from_public_bytes(peer_pub))
    except ValueError:
        return None  # cryptography refuses an all-zero shared secret itself
    if ss == bytes(32):
        return None
    return ss


def ed_verify(pub: bytes, msg: bytes, sig: bytes) -> bool:
    try:
        Ed25519PublicKey.from_public_bytes(pub).verify(sig, msg)
        return True
    except (InvalidSignature, ValueError):
        return False


def seal(key: bytes, aad: bytes, pt: bytes) -> bytes:
    return AESGCM(key).encrypt(ZERO_NONCE, pt, aad)


def open_sealed(key: bytes, aad: bytes, ct: bytes):
    try:
        return AESGCM(key).decrypt(ZERO_NONCE, ct, aad)
    except InvalidTag:
        return None


def sas_digits(sas_bytes: bytes) -> str:
    return "%06d" % (struct.unpack(">Q", sas_bytes)[0] % 1_000_000)


def v1_sas(a: bytes, b: bytes) -> str:
    """The v1 identity-only SAS (SasComputation.kt), for comparison only."""
    first, second = (a, b) if a <= b else (b, a)
    prk = hmac256(b"qaudion-sas-v1", first + second)
    return "%06d" % (struct.unpack(">I", prk[:4])[0] % 1_000_000)


# ---------------------------------------------------------------- encodings


def id_block(id_pub: bytes, user_id: str) -> bytes:
    u = user_id.encode("utf-8")
    return id_pub + bytes([len(u)]) + u


def valid_user_id(u: bytes) -> bool:
    return len(u) <= USER_ID_MAX and all(c in USER_ID_ALPHABET for c in u)


def parse_id_block(b: bytes):
    """Returns (idPub, userIdBytes, rest) or raises ValueError(token)."""
    if len(b) < 33:
        raise ValueError("length")
    n = b[32]
    if n > USER_ID_MAX or len(b) < 33 + n:
        raise ValueError("length")
    u = b[33 : 33 + n]
    if not valid_user_id(u):
        raise ValueError("user_id")
    return b[:32], u, b[33 + n :]


def check_peer_identity(peer_pub: bytes, own_pub: bytes):
    """Identity checks of §9 / §3: not our own key; canonical; in the prime-order subgroup."""
    if peer_pub == own_pub:
        return "identity_self"
    if peer_pub in SMALL_ORDER:  # fast path only
        return "identity_invalid"
    if not ed_identity_key_ok(peer_pub):
        return "identity_invalid"
    return None


def apdu(ins: int, p1: int = 0, p2: int = 0, data: bytes = b"", le=None) -> bytes:
    out = bytes([CLA, ins, p1, p2])
    if data:
        assert 1 <= len(data) <= 255
        out += bytes([len(data)]) + data
    if le is not None:
        out += bytes([le & 0xFF])  # Le = 0x00 means "up to 256"
    return out


def select_apdu() -> bytes:
    return bytes([0x00, 0xA4, 0x04, 0x00, len(AID)]) + AID + bytes([0x00])


# ---------------------------------------------------------------- one exchange


class Party:
    def __init__(self, name: str, user_id: str):
        self.name = name
        self.id_sk = Ed25519PrivateKey.from_private_bytes(det(name + "/ed25519-seed", 32))
        self.id_pub = ed_pub(self.id_sk)
        self.user_id = user_id
        self.id_block = id_block(self.id_pub, user_id)


def run_exchange(reader: Party, card: Party, sess: str, overrides=None):
    """Runs tap 1 + tap 2 for one session label. Returns a dict of everything."""
    o = overrides or {}
    x_r = X25519PrivateKey.from_private_bytes(det(sess + "/x25519-reader", 32))
    x_c = X25519PrivateKey.from_private_bytes(det(sess + "/x25519-card", 32))
    xpk_r = x_pub(x_r)
    xpk_c = o.get("xpk_c", x_pub(x_c))
    nonce_r = det(sess + "/nonce-reader", 32)
    nonce_c = det(sess + "/nonce-card", 32)
    kem_seed = det(sess + "/mlkem-seed", 64)
    kem_sk = MLKEM1024PrivateKey.from_seed_bytes(kem_seed)
    ek_r = kem_sk.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    assert len(ek_r) == EK_LEN
    ct_c = det(sess + "/mlkem-ct", CT_LEN)
    ss_kem = kem_sk.decapsulate(ct_c)

    select_data = bytes([VERSION])
    commit_r = sha256(L["commit"] + nonce_r + lp32(reader.id_block))
    hello_cmd = bytes([VERSION]) + xpk_r + commit_r
    hello_resp = xpk_c + nonce_c

    ss_x = x25519(x_r, xpk_c)
    if ss_x is None:
        return {"abort": "x25519_zero"}
    assert ss_x == x25519(x_c, xpk_r)

    th1 = sha256(L["th1"] + lp32(select_data) + lp32(ek_r) + lp32(hello_cmd) + lp32(hello_resp) + lp32(ct_c))
    prk1 = hkdf_extract(th1, ss_kem + ss_x)
    k_enc_c = hkdf_expand(prk1, L["enc_c"], 32)
    k_enc_r = hkdf_expand(prk1, L["enc_r"], 32)
    k_mac_c = hkdf_expand(prk1, L["mac_c"], 32)
    k_mac_r = hkdf_expand(prk1, L["mac_r"], 32)

    # Card identity proof (AUTH_C response).
    th_c = sha256(L["th_c"] + th1 + lp32(card.id_block))
    sig_c = card.id_sk.sign(L["sig_c"] + th_c)
    mac_c = hmac256(k_mac_c, th_c)
    sealed_c = seal(k_enc_c, th1, card.id_block + sig_c + mac_c)

    # Reader opening + identity proof (REVEAL command).
    th_r = sha256(L["th_r"] + th_c + lp32(reader.id_block) + nonce_r)
    sig_r = reader.id_sk.sign(L["sig_r"] + th_r)
    mac_r = hmac256(k_mac_r, th_r)
    sealed_r = seal(k_enc_r, th_c, reader.id_block + nonce_r + sig_r + mac_r)

    prk2 = hkdf_extract(th_r, prk1 + nonce_r + nonce_c)
    k_confirm_r = hkdf_expand(prk2, L["confirm_r"], 32)
    k_confirm_c = hkdf_expand(prk2, L["confirm_c"], 32)
    sas_bytes = hkdf_expand(prk2, L["sas"], 8)
    psk = hkdf_expand(prk2, L["psk"], 32)

    confirm_r = hmac256(k_confirm_r, L["confirmed"])
    reject_r = hmac256(k_confirm_r, L["rejected"])
    final_r = hmac256(k_confirm_r, L["final"])
    confirm_c = hmac256(k_confirm_c, L["confirmed"])
    reject_c = hmac256(k_confirm_c, L["rejected"])

    # Self-check: both sides open and verify what the other sent.
    pt = open_sealed(k_enc_c, th1, sealed_c)
    assert pt is not None
    pid, puid, rest = parse_id_block(pt)
    assert ed_verify(pid, L["sig_c"] + sha256(L["th_c"] + th1 + lp32(pt[: 33 + len(puid)])), rest[:64])
    pt = open_sealed(k_enc_r, th_c, sealed_r)
    assert pt is not None
    assert sha256(L["commit"] + pt[33 + len(reader.user_id) : 33 + len(reader.user_id) + 32] + lp32(reader.id_block)) == commit_r

    apdus = [{"name": "SELECT", "command": select_apdu(), "response": select_data + SW_OK}]
    for i in range(CHUNKS):
        apdus.append({
            "name": "EK_PUT[%d]" % i,
            "command": apdu(INS["EK_PUT"], i, CHUNKS, ek_r[i * CHUNK : (i + 1) * CHUNK]),
            "response": SW_OK,
        })
    apdus.append({"name": "HELLO", "command": apdu(INS["HELLO"], data=hello_cmd, le=64), "response": hello_resp + SW_OK})
    for i in range(CHUNKS):
        apdus.append({
            "name": "CT_GET[%d]" % i,
            "command": apdu(INS["CT_GET"], i, CHUNKS, le=CHUNK),
            "response": ct_c[i * CHUNK : (i + 1) * CHUNK] + SW_OK,
        })
    apdus.append({"name": "AUTH_C", "command": apdu(INS["AUTH_C"], le=0), "response": sealed_c + SW_OK})
    apdus.append({"name": "REVEAL", "command": apdu(INS["REVEAL"], data=sealed_r), "response": SW_OK})
    # Tap 2 (or the same field): reader confirms, card already confirmed.
    apdus.append({"name": "SELECT (tap 2)", "command": select_apdu(), "response": select_data + SW_OK})
    apdus.append({
        "name": "CONFIRM (card pending)",
        "command": apdu(INS["CONFIRM"], data=bytes([DECISION_CONFIRM]) + confirm_r, le=0),
        "response": bytes([STATE_PENDING]) + SW_OK,
    })
    apdus.append({
        "name": "CONFIRM (card confirmed)",
        "command": apdu(INS["CONFIRM"], data=bytes([DECISION_CONFIRM]) + confirm_r, le=0),
        "response": bytes([STATE_CONFIRMED]) + confirm_c + SW_OK,
    })
    apdus.append({"name": "FINALIZE", "command": apdu(INS["FINALIZE"], data=final_r, le=0), "response": bytes([STATE_CONFIRMED]) + SW_OK})
    apdus.append({"name": "FINALIZE (repeat)", "command": apdu(INS["FINALIZE"], data=final_r, le=0), "response": bytes([STATE_CONFIRMED]) + SW_OK})
    apdus.append({
        "name": "CONFIRM (repeat after FINALIZE)",
        "command": apdu(INS["CONFIRM"], data=bytes([DECISION_CONFIRM]) + confirm_r, le=0),
        "response": bytes([STATE_CONFIRMED]) + confirm_c + SW_OK,
    })

    for a in apdus:
        assert len(a["command"]) <= 5 + 255 + 1, a["name"]
        assert len(a["response"]) <= 256 + 2, a["name"]

    return {
        "inputs": {
            "reader": {"ed25519Seed": det(reader.name + "/ed25519-seed", 32), "idPub": reader.id_pub,
                       "userId": reader.user_id, "idBlock": reader.id_block},
            "card": {"ed25519Seed": det(card.name + "/ed25519-seed", 32), "idPub": card.id_pub,
                     "userId": card.user_id, "idBlock": card.id_block},
            "x25519PrivReader": det(sess + "/x25519-reader", 32),
            "x25519PrivCard": det(sess + "/x25519-card", 32),
            "xpkReader": xpk_r,
            "xpkCard": xpk_c,
            "nonceReader": nonce_r,
            "nonceCard": nonce_c,
            "mlkemSeedReader": kem_seed,
            "mlkemEk": ek_r,
            "mlkemCt": ct_c,
            "mlkemSs": ss_kem,
        },
        "derived": {
            "selectData": select_data,
            "commitReader": commit_r,
            "helloCommandData": hello_cmd,
            "helloResponseData": hello_resp,
            "ssX25519": ss_x,
            "th1": th1,
            "prk1": prk1,
            "kEncCard": k_enc_c,
            "kEncReader": k_enc_r,
            "kMacCard": k_mac_c,
            "kMacReader": k_mac_r,
            "thCard": th_c,
            "sigCard": sig_c,
            "macCard": mac_c,
            "sealedCard": sealed_c,
            "thReader": th_r,
            "sigReader": sig_r,
            "macReader": mac_r,
            "sealedReader": sealed_r,
            "prk2": prk2,
            "kConfirmReader": k_confirm_r,
            "kConfirmCard": k_confirm_c,
            "sasBytes": sas_bytes,
            "sas": sas_digits(sas_bytes),
            "psk": psk,
            "pskFingerprint": sha256(psk).hex(),
            "confirmReader": confirm_r,
            "rejectReader": reject_r,
            "finalizeReader": final_r,
            "confirmCard": confirm_c,
            "rejectCard": reject_c,
            "logTag": sha256(L["log"] + th1)[:4].hex(),
            "v1SasSameIdentities": v1_sas(reader.id_pub, card.id_pub),
        },
        "apdus": apdus,
        "_k": {"k_enc_c": k_enc_c, "k_enc_r": k_enc_r, "k_mac_c": k_mac_c, "k_mac_r": k_mac_r,
               "th1": th1, "th_c": th_c, "th_r": th_r, "sealed_c": sealed_c, "sealed_r": sealed_r,
               "commit_r": commit_r, "nonce_r": nonce_r, "k_confirm_r": k_confirm_r,
               "k_confirm_c": k_confirm_c, "confirm_r": confirm_r, "confirm_c": confirm_c,
               "reject_r": reject_r, "reject_c": reject_c, "sig_c": sig_c, "mac_c": mac_c},
    }


# ---------------------------------------------------------------- negative cases


def card_auth_verdict(k, own_reader_pub: bytes, sealed: bytes, expected_pub=None):
    """Reader-side check of an AUTH_C response. Returns None (accept) or a token."""
    pt = open_sealed(k["k_enc_c"], k["th1"], sealed)
    if pt is None:
        return "open_failed"
    try:
        pid, uid, rest = parse_id_block(pt)
    except ValueError as e:
        return str(e)
    if len(rest) != 64 + 32:
        return "length"
    blk = pt[: 33 + len(uid)]
    sig, mac = rest[:64], rest[64:]
    bad = check_peer_identity(pid, own_reader_pub)
    if bad:
        return bad
    th_c = sha256(L["th_c"] + k["th1"] + lp32(blk))
    if not hmac.compare_digest(hmac256(k["k_mac_c"], th_c), mac):
        return "mac"
    if not ed_verify(pid, L["sig_c"] + th_c, sig):
        return "signature"
    if expected_pub is not None and pid != expected_pub:
        return "peer_identity_changed"
    return None


def reveal_verdict(k, own_card_pub: bytes, sealed: bytes):
    """Card-side check of a REVEAL command. Returns None (accept) or a token."""
    pt = open_sealed(k["k_enc_r"], k["th_c"], sealed)
    if pt is None:
        return "open_failed"
    try:
        pid, uid, rest = parse_id_block(pt)
    except ValueError as e:
        return str(e)
    if len(rest) != 32 + 64 + 32:
        return "length"
    blk = pt[: 33 + len(uid)]
    nonce_r, sig, mac = rest[:32], rest[32:96], rest[96:]
    if not hmac.compare_digest(sha256(L["commit"] + nonce_r + lp32(blk)), k["commit_r"]):
        return "commitment"
    bad = check_peer_identity(pid, own_card_pub)
    if bad:
        return bad
    th_r = sha256(L["th_r"] + k["th_c"] + lp32(blk) + nonce_r)
    if not hmac.compare_digest(hmac256(k["k_mac_r"], th_r), mac):
        return "mac"
    if not ed_verify(pid, L["sig_r"] + th_r, sig):
        return "signature"
    return None


def main():
    reader = Party("iphone-alice", "3f0b7a52-6a4e-4c1e-9d2f-0c5b1e7a9d01")
    card = Party("android-bob", "8c1d2e3f-4a5b-4c6d-8e7f-90a1b2c3d4e5")
    mallory = Party("mallory", "11111111-2222-4333-8444-555555555555")

    ex = run_exchange(reader, card, "session-1")
    k = ex.pop("_k")
    ex2 = run_exchange(reader, card, "session-2")
    k2 = ex2.pop("_k")

    neg = []

    def add(name, desc, side, verdict, expect, **extra):
        assert verdict == expect, (name, verdict, expect)
        d = {"name": name, "description": desc, "checkedBy": side, "expect": "reject" if expect else "accept"}
        if expect:
            d["reason"] = expect
        d.update(extra)
        neg.append(d)

    # Positive controls.
    add("card_auth_valid", "The genuine AUTH_C response of session-1.", "reader",
        card_auth_verdict(k, reader.id_pub, k["sealed_c"]), None)
    add("reveal_valid", "The genuine REVEAL of session-1.", "card",
        reveal_verdict(k, card.id_pub, k["sealed_r"]), None)

    # 1. Key substitution: Mallory presents Bob's public key but can only sign with her own key.
    blk = id_block(card.id_pub, card.user_id)
    th_c = sha256(L["th_c"] + k["th1"] + lp32(blk))
    forged_sig = mallory.id_sk.sign(L["sig_c"] + th_c)
    forged = seal(k["k_enc_c"], k["th1"], blk + forged_sig + hmac256(k["k_mac_c"], th_c))
    add("substituted_identity_key", "Card presents another person's Ed25519 key (Bob) with a correct MAC "
        "but a signature made with its own key (Mallory). Must fail before anything is stored.",
        "reader", card_auth_verdict(k, reader.id_pub, forged), "signature", sealedCard=forged)

    # 2. Replay of a genuine signature from another session.
    replay = seal(k["k_enc_c"], k["th1"], card.id_block + k2["sig_c"] + k["mac_c"])
    add("replayed_signature", "Card replays Bob's genuine signature from session-2 inside session-1.",
        "reader", card_auth_verdict(k, reader.id_pub, replay), "signature", sealedCard=replay)

    # 3. Tampered sealed box.
    t = bytearray(k["sealed_c"]); t[10] ^= 0x01
    add("tampered_sealed_card", "One bit of the AUTH_C sealed box flipped.", "reader",
        card_auth_verdict(k, reader.id_pub, bytes(t)), "open_failed", sealedCard=bytes(t))

    # 4. MAC under the wrong key.
    wrong_mac = seal(k["k_enc_c"], k["th1"], card.id_block + k["sig_c"] + hmac256(k["k_mac_r"], k["th_c"]))
    add("mac_wrong_key", "AUTH_C MAC computed with K_mac_reader instead of K_mac_card.", "reader",
        card_auth_verdict(k, reader.id_pub, wrong_mac), "mac", sealedCard=wrong_mac)

    # 5. Commitment broken: REVEAL opens to a different user id than committed in HELLO.
    other_blk = id_block(reader.id_pub, mallory.user_id)
    th_r = sha256(L["th_r"] + k["th_c"] + lp32(other_blk) + k["nonce_r"])
    bad_reveal = seal(k["k_enc_r"], k["th_c"], other_blk + k["nonce_r"] + reader.id_sk.sign(L["sig_r"] + th_r)
                      + hmac256(k["k_mac_r"], th_r))
    add("commitment_mismatch_identity", "REVEAL carries an identity block other than the one committed in HELLO "
        "(signature and MAC are otherwise valid).", "card",
        reveal_verdict(k, card.id_pub, bad_reveal), "commitment", sealedReader=bad_reveal)
    other_nonce = det("other-nonce", 32)
    th_r = sha256(L["th_r"] + k["th_c"] + lp32(reader.id_block) + other_nonce)
    bad_reveal2 = seal(k["k_enc_r"], k["th_c"], reader.id_block + other_nonce
                       + reader.id_sk.sign(L["sig_r"] + th_r) + hmac256(k["k_mac_r"], th_r))
    add("commitment_mismatch_nonce", "REVEAL opens the commitment with a different nonce.", "card",
        reveal_verdict(k, card.id_pub, bad_reveal2), "commitment", sealedReader=bad_reveal2)

    # 6. Self identity.
    th_c_self = sha256(L["th_c"] + k["th1"] + lp32(reader.id_block))
    self_box = seal(k["k_enc_c"], k["th1"], reader.id_block + reader.id_sk.sign(L["sig_c"] + th_c_self)
                    + hmac256(k["k_mac_c"], th_c_self))
    add("self_identity", "Card presents the reader's own identity key (loop-back).", "reader",
        card_auth_verdict(k, reader.id_pub, self_box), "identity_self", sealedCard=self_box)

    # 7. Small-order identity key.
    so_blk = id_block(SMALL_ORDER[0], card.user_id)
    th_so = sha256(L["th_c"] + k["th1"] + lp32(so_blk))
    so_box = seal(k["k_enc_c"], k["th1"], so_blk + bytes(64) + hmac256(k["k_mac_c"], th_so))
    add("small_order_identity", "Card presents the Ed25519 identity point (small order).", "reader",
        card_auth_verdict(k, reader.id_pub, so_box), "identity_invalid", sealedCard=so_box)

    # 7b. Mixed-order identity key: Bob's key plus an order-8 torsion point. Decodes and is
    # canonical, is not in the small-order table, but [l]A != O.
    mixed = ed_encode(ed_add(ed_decode(card.id_pub), ed_decode(SMALL_ORDER[4])))
    assert ed_decode(mixed) is not None and mixed not in SMALL_ORDER and not ed_identity_key_ok(mixed)
    assert ed_identity_key_ok(card.id_pub) and ed_identity_key_ok(reader.id_pub)
    mx_blk = id_block(mixed, card.user_id)
    th_mx = sha256(L["th_c"] + k["th1"] + lp32(mx_blk))
    mx_box = seal(k["k_enc_c"], k["th1"], mx_blk + bytes(64) + hmac256(k["k_mac_c"], th_mx))
    add("mixed_order_identity", "Card presents A + T (T of order 8): canonical, not in the small-order "
        "table, outside the prime-order subgroup.", "reader",
        card_auth_verdict(k, reader.id_pub, mx_box), "identity_invalid", idPub=mixed, sealedCard=mx_box)

    # 7c. Non-canonical encoding (y = 1 + p: the identity point written with y >= p).
    noncanon = bytes.fromhex("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")
    assert noncanon not in SMALL_ORDER and ed_decode(noncanon) is None
    nc_blk = id_block(noncanon, card.user_id)
    th_nc = sha256(L["th_c"] + k["th1"] + lp32(nc_blk))
    nc_box = seal(k["k_enc_c"], k["th1"], nc_blk + bytes(64) + hmac256(k["k_mac_c"], th_nc))
    add("non_canonical_identity", "Card presents a non-canonical encoding (y >= p) not in the small-order table.",
        "reader", card_auth_verdict(k, reader.id_pub, nc_box), "identity_invalid", idPub=noncanon, sealedCard=nc_box)

    # 7d. Reader presents the card's own identity at REVEAL (commitment over that block, so it opens).
    loop_reader = Party("android-bob", card.user_id)
    ls = run_exchange(loop_reader, card, "session-loop")
    lk = ls.pop("_k")
    add("self_identity_at_reveal", "Reader presents the card's own identity key; the commitment opens, the "
        "card must refuse.", "card", reveal_verdict(lk, card.id_pub, lk["sealed_r"]), "identity_self",
        sealedReader=lk["sealed_r"], kEncReader=lk["k_enc_r"], thCard=lk["th_c"], commitReader=lk["commit_r"])

    # 7e. REVEAL with one trailing byte after the MAC.
    pt_ok = open_sealed(k["k_enc_r"], k["th_c"], k["sealed_r"])
    trailing = seal(k["k_enc_r"], k["th_c"], pt_ok + bytes(1))
    add("reveal_trailing_bytes", "REVEAL plaintext with one extra byte after mac_R.", "card",
        reveal_verdict(k, card.id_pub, trailing), "length", sealedReader=trailing)

    # 8. User id grammar.
    long_blk = card.id_pub + bytes([65]) + b"a" * 65
    add("user_id_too_long", "Identity block with a 65-byte user id.", "reader",
        card_auth_verdict(k, reader.id_pub, seal(k["k_enc_c"], k["th1"], long_blk + bytes(96))), "length")
    bad_chars = card.id_pub + bytes([5]) + b"ab|cd"
    add("user_id_bad_char", "Identity block whose user id contains '|'.", "reader",
        card_auth_verdict(k, reader.id_pub, seal(k["k_enc_c"], k["th1"], bad_chars + bytes(96))), "user_id")

    # 9. Pinned identity changed (re-pairing with a contact whose key is stored).
    th_m = sha256(L["th_c"] + k["th1"] + lp32(mallory.id_block))
    m_box = seal(k["k_enc_c"], k["th1"], mallory.id_block + mallory.id_sk.sign(L["sig_c"] + th_m)
                 + hmac256(k["k_mac_c"], th_m))
    assert card_auth_verdict(k, reader.id_pub, m_box) is None  # a valid proof of Mallory's own key
    add("pinned_identity_changed", "A fully valid AUTH_C proving Mallory's own key, while the reader runs a "
        "contact-targeted re-pairing that expects Bob's stored key.", "reader",
        card_auth_verdict(k, reader.id_pub, m_box, expected_pub=card.id_pub), "peer_identity_changed",
        sealedCard=m_box, expectedIdPub=card.id_pub)

    # 10. X25519 all-zero.
    zero = run_exchange(reader, card, "session-zero", overrides={"xpk_c": bytes(32)})
    assert zero == {"abort": "x25519_zero"}
    neg.append({"name": "x25519_all_zero", "description": "Card HELLO response carries the X25519 point 0; the "
                "shared secret is all zero and must be refused.", "checkedBy": "both", "expect": "reject",
                "reason": "x25519_zero", "xpkCard": bytes(32)})

    # 11. Confirmation tags.
    neg.append({"name": "confirm_tags_distinct", "description": "Each tag verifies only as itself.",
                "checkedBy": "both", "expect": "reject", "reason": "confirm_tag",
                "cases": [
                    {"presentedAs": "confirmReader", "value": k["confirm_c"], "accept": False},
                    {"presentedAs": "confirmReader", "value": k["reject_r"], "accept": False},
                    {"presentedAs": "confirmReader", "value": k2["confirm_r"], "accept": False},
                    {"presentedAs": "confirmReader", "value": k["confirm_r"], "accept": True},
                ]})
    assert len({k["confirm_c"], k["reject_r"], k2["confirm_r"], k["confirm_r"]}) == 4

    # 11b. Reject flows. Reader rejects: card verifies reject_R, aborts, answers 04. Card rejected:
    # the reader accepts 02 as a rejection only when reject_C verifies.
    assert k["reject_c"] != k["reject_r"]
    neg.append({"name": "reject_flow", "description": "CONFIRM carrying a reader rejection, and the card's "
                "rejection answer. No key is stored on either side.", "checkedBy": "both", "expect": "reject",
                "reason": "user_rejected",
                "readerRejects": {"command": apdu(INS["CONFIRM"], data=bytes([DECISION_REJECT]) + k["reject_r"], le=0),
                                  "response": bytes([STATE_ABORTED]) + SW_OK},
                "cardRejected": {"command": apdu(INS["CONFIRM"], data=bytes([DECISION_CONFIRM]) + k["confirm_r"], le=0),
                                 "response": bytes([STATE_REJECTED]) + k["reject_c"] + SW_OK,
                                 "forgedResponse": bytes([STATE_REJECTED]) + k["reject_r"] + SW_OK,
                                 "forgedVerdict": "treated as 03: the tag does not verify as reject_C"},
                "rejectTagAsConfirm": {"command": apdu(INS["CONFIRM"], data=bytes([DECISION_CONFIRM]) + k["reject_r"], le=0),
                                       "response": bytes([STATE_NONE]) + SW_OK}})

    # 12. Man in the middle with honest randomness on both ends: each victim sees its own SAS.
    m1 = run_exchange(reader, mallory, "mitm-reader-side")
    m2 = run_exchange(mallory, card, "mitm-card-side")
    m1.pop("_k"); m2.pop("_k")
    sas_r, sas_c = m1["derived"]["sas"], m2["derived"]["sas"]
    assert sas_r != sas_c
    neg.append({"name": "mitm_two_sessions", "description": "Mallory runs one session with the reader (as card) and "
                "one with the card (as reader). With the commitment she cannot choose her values after seeing the "
                "victim's random, so the two SAS values are independent; here they differ. Each victim also sees "
                "Mallory's identity, never the other victim's.",
                "checkedBy": "users", "expect": "reject", "reason": "sas_mismatch",
                "sasOnReader": sas_r, "sasOnCard": sas_c,
                "readerSeesPeerIdPub": mallory.id_pub, "cardSeesPeerIdPub": mallory.id_pub})

    # 13. Fresh SAS per session (v1 was static per identity pair).
    assert ex["derived"]["sas"] != ex2["derived"]["sas"]
    assert ex["derived"]["v1SasSameIdentities"] == ex2["derived"]["v1SasSameIdentities"]
    neg.append({"name": "sas_per_session", "description": "Same two identities, two sessions: v2 SAS differs, the "
                "v1 identity-only SAS is the same every time.", "checkedBy": "both", "expect": "accept",
                "sasSession1": ex["derived"]["sas"], "sasSession2": ex2["derived"]["sas"],
                "v1Sas": ex["derived"]["v1SasSameIdentities"]})

    # 14. Framing errors the card must refuse. The all-0xFF key must fail the FIPS 203 modulus check.
    from cryptography.hazmat.primitives.asymmetric.mlkem import MLKEM1024PublicKey
    try:
        MLKEM1024PublicKey.from_public_bytes(bytes([0xFF]) * EK_LEN)
        raise AssertionError("all-0xFF ML-KEM key accepted")
    except ValueError:
        pass
    MLKEM1024PublicKey.from_public_bytes(ex["inputs"]["mlkemEk"])  # the vector key passes
    neg.append({"name": "framing", "description": "Card status words for malformed commands.", "checkedBy": "card",
                "expect": "reject", "reason": "length",
                "cases": [
                    {"command": apdu(INS["HELLO"], data=bytes([VERSION]) + bytes(63)), "sw": "6700"},
                    {"command": apdu(INS["HELLO"], data=bytes([0x01]) + bytes(64)), "sw": "6A80"},
                    {"command": apdu(INS["EK_PUT"], 7, 7, bytes(CHUNK)), "sw": "6A86"},
                    {"command": apdu(INS["EK_PUT"], 0, 7, bytes(CHUNK - 1)), "sw": "6700"},
                    {"command": apdu(INS["CONFIRM"], data=bytes([0x03]) + bytes(32), le=0), "sw": "6A80"},
                    {"command": bytes([CLA, 0xC4, 0x00, 0x00, 0x20]), "sw": "6D00"},
                    {"after": "EK_PUT[0]", "command": apdu(INS["EK_PUT"], 2, 7, bytes(CHUNK)), "sw": "6985",
                     "note": "chunk out of order"},
                    {"after": "EK_PUT[0] of the session-1 exchange",
                     "command": apdu(INS["EK_PUT"], 0, 7, ex["inputs"]["mlkemEk"][:CHUNK]), "sw": "9000",
                     "note": "last chunk repeated with identical bytes"},
                    {"after": "EK_PUT[0] of the session-1 exchange",
                     "command": apdu(INS["EK_PUT"], 0, 7, bytes(CHUNK)), "sw": "6A80",
                     "note": "last chunk repeated with different bytes"},
                    {"after": "EK_PUT[0..6] carrying an all-0xFF key", "command": apdu(INS["EK_PUT"], 6, 7, bytes([0xFF]) * CHUNK),
                     "sw": "6A80", "note": "encapsulation key fails the FIPS 203 modulus check (token kem)"},
                    {"after": "no ceremony", "command": apdu(INS["FINALIZE"], data=bytes(32), le=0),
                     "response": "03", "sw": "9000", "note": "FINALIZE tag matches nothing"},
                ]})

    def enc(v):
        if isinstance(v, (bytes, bytearray)):
            return bytes(v).hex()
        if isinstance(v, dict):
            return {kk: enc(vv) for kk, vv in v.items()}
        if isinstance(v, list):
            return [enc(x) for x in v]
        return v

    doc = {
        "spec": "NFC_PAIRING_V2.md",
        "protocolVersion": VERSION,
        "note": "All byte strings are lowercase hex. ML-KEM: real reader key pair from mlkemSeedReader; ct is fixed "
                "bytes and mlkemSs is FIPS 203 decapsulation of it (implicit rejection), not a real encapsulation. "
                "Ed25519 signatures are RFC 8032 deterministic; randomized signers must verify, not compare.",
        "aid": AID,
        "cla": CLA,
        "ins": INS,
        "chunk": {"size": CHUNK, "count": CHUNKS},
        "userIdMax": USER_ID_MAX,
        "labels": {kk: vv.decode() for kk, vv in L.items()},
        "exchange": ex,
        "exchangeSession2": {"derived": {kk: ex2["derived"][kk] for kk in ("th1", "thReader", "sas", "psk")}},
        "negative": neg,
    }
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nfc-pairing-kat.json")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(enc(doc), f, indent=2, sort_keys=False)
        f.write("\n")
    print("wrote", out)
    print("sas", ex["derived"]["sas"], "psk-fp", ex["derived"]["pskFingerprint"][:16], "negatives", len(neg))


if __name__ == "__main__":
    main()
