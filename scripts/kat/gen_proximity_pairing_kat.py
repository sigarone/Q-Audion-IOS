#!/usr/bin/env python3
"""Reference vectors for proximity pairing v1 (QR + BLE, hybrid ML-KEM-1024).

Independent implementation of docs/security/PROXIMITY_PAIRING_QR_BLE_SPEC.md
sections 5, 6, 7, 8 and 10: hashlib/hmac for the hashes and HKDF, and the
`cryptography` package for AES-256-GCM and Ed25519 (RFC 8032, deterministic).
The ML-KEM-1024 and X25519 shared secrets and the ephemeral public keys are
fixed byte strings here: this file pins everything the protocol derives from
them, not the KEM itself. The identity keys are real Ed25519 keys from fixed
seeds, so the signatures in the vector verify.

Writes QAudionEngine/Tests/QAudionEngineTests/Proximity/Resources/
proximity-pairing-kat.json (consumed by ProximityPairingKatTests.swift).
"""

import base64
import hashlib
import hmac
import json
import os
import struct

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

ZERO_NONCE = bytes(12)

L = {
    "commit": b"qaudion-prox-v1/commit",
    "frame": b"qaudion-prox-v1/frame",
    "hello": b"qaudion-prox-v1/hello",
    "transcript": b"qaudion-prox-v1/transcript",
    "th_s": b"qaudion-prox-v1/transcript-scanner",
    "th_d": b"qaudion-prox-v1/transcript-displayer",
    "enc_s": b"qaudion-prox-v1/enc-scanner",
    "enc_d": b"qaudion-prox-v1/enc-displayer",
    "mac_s": b"qaudion-prox-v1/mac-scanner",
    "mac_d": b"qaudion-prox-v1/mac-displayer",
    "confirm_s": b"qaudion-prox-v1/confirm-scanner",
    "confirm_d": b"qaudion-prox-v1/confirm-displayer",
    "sas": b"qaudion-prox-v1/sas",
    "psk": b"qaudion-prox-v1/psk",
    "sig_s": b"qaudion-prox-v1/sig-scanner",
    "sig_d": b"qaudion-prox-v1/sig-displayer",
    "confirmed": b"qaudion-prox-v1/user-confirmed",
}

MSG_HELLO, MSG_OFFER, MSG_ACCEPT, MSG_FINISH, MSG_CONFIRM, MSG_ABORT, MSG_BUSY = 1, 2, 3, 4, 5, 6, 7

# Spec §8 userId grammar: 1..256 bytes, each in [A-Za-z0-9._-].
USER_ID_ALPHABET = set(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")


def valid_user_id(u: str) -> bool:
    b = u.encode("utf-8")
    return 1 <= len(b) <= 256 and all(c in USER_ID_ALPHABET for c in b)


def sha256(b: bytes) -> bytes:
    return hashlib.sha256(b).digest()


def hmac256(key: bytes, msg: bytes) -> bytes:
    return hmac.new(key, msg, hashlib.sha256).digest()


def hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    return hmac256(salt, ikm)


def hkdf_expand(prk: bytes, info: bytes, length: int) -> bytes:
    out, t, counter = b"", b"", 1
    while len(out) < length:
        t = hmac256(prk, t + info + bytes([counter]))
        out += t
        counter += 1
    return out[:length]


def u16be(n: int) -> bytes:
    return struct.pack(">H", n)


def u32be(n: int) -> bytes:
    return struct.pack(">I", n)


def lp32(b: bytes) -> bytes:
    return u32be(len(b)) + b


def filler(tag: str, n: int) -> bytes:
    """Deterministic, obviously-synthetic bytes (NOT a valid ML-KEM key)."""
    out, i = b"", 0
    while len(out) < n:
        out += sha256(f"kat-{tag}-{i}".encode())
        i += 1
    return out[:n]


def b64url_nopad(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def fragment(message: bytes, max_value_length: int):
    cap = max_value_length - 2
    assert cap >= 1
    chunks = [message[i:i + cap] for i in range(0, len(message), cap)] or [b""]
    assert chunks[0], "empty messages are not framed"
    assert len(chunks) <= 256
    frags = []
    for seq, chunk in enumerate(chunks):
        flags = (0x01 if seq == 0 else 0) | (0x02 if seq == len(chunks) - 1 else 0)
        frags.append(bytes([flags, seq]) + chunk)
    return frags


def sas_from_bytes(b: bytes) -> str:
    return "%06d" % (struct.unpack(">Q", b)[0] % 1_000_000)


VALID_USER_IDS = [
    "a",
    "user-S-42",
    "66666666-6666-6666-6666-666666666666",
    "A.b_c-9",
    "x" * 256,
]

INVALID_USER_IDS = [
    "",
    " alice",
    "alice ",
    "ali ce",
    "alice\u00a0",
    "alice\u200b",
    "alice\n",
    "ali|ce",
    "ali:ce",
    "ali/ce",
    "ünï",
    "x" * 257,
]


def aes_gcm_seal(key: bytes, aad: bytes, plaintext: bytes) -> bytes:
    """AES-256-GCM, 12-byte all-zero nonce (each key seals exactly one message),
    16-byte tag appended: returns ciphertext || tag."""
    assert len(key) == 32
    return AESGCM(key).encrypt(ZERO_NONCE, plaintext, aad)


def id_block(idpub: bytes, encpub: bytes, user_id: str) -> bytes:
    u = user_id.encode("utf-8")
    assert valid_user_id(user_id)
    return idpub + encpub + u16be(len(u)) + u


def main() -> None:
    for u in VALID_USER_IDS:
        assert valid_user_id(u), u
    for u in INVALID_USER_IDS:
        assert not valid_user_id(u), repr(u)

    session_secret = bytes(range(0x00, 0x20))
    session_id = bytes(range(0x40, 0x50))
    frame_index = 7

    # Displayer: ephemeral keys (fixed synthetic bytes) + a REAL Ed25519
    # identity from a fixed seed (RFC 8032 signing is deterministic).
    ek_d = filler("ek-d", 1568)
    xpk_d = filler("xpk-d", 32)
    nonce_d = filler("nonce-d", 32)
    seed_d = filler("idseed-d", 32)
    sk_d = Ed25519PrivateKey.from_private_bytes(seed_d)
    idpub_d = sk_d.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    encpub_d = filler("encpub-d", 32)
    user_d = "utente-D.42_kat"  # every punctuation character the §8 grammar allows

    xpk_s = filler("xpk-s", 32)
    nonce_s = filler("nonce-s", 32)
    ct = filler("ct", 1568)
    seed_s = filler("idseed-s", 32)
    sk_s = Ed25519PrivateKey.from_private_bytes(seed_s)
    idpub_s = sk_s.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    encpub_s = filler("encpub-s", 32)
    user_s = "user-S-42"

    ss_kem = filler("ss-kem", 32)
    ss_x = filler("ss-x", 32)

    # §8 OFFER: ephemeral keys only — no identity on the air in clear.
    offer_body = ek_d + xpk_d + nonce_d
    assert len(offer_body) == 1632
    commitment = sha256(L["commit"] + session_id + offer_body)

    frame_key_0 = hmac256(session_secret, L["frame"] + session_id + u32be(0))
    frame_key = hmac256(session_secret, L["frame"] + session_id + u32be(frame_index))
    qr_bytes = bytes([0x01]) + session_id + commitment + u32be(frame_index) + frame_key
    assert len(qr_bytes) == 85
    qr_text = "qaudion://pair/" + b64url_nopad(qr_bytes)
    assert len(qr_text) == len("qaudion://pair/") + 114

    tag = hmac256(frame_key, L["hello"] + session_id + u32be(frame_index) + xpk_s + nonce_s)
    hello_body = u32be(frame_index) + xpk_s + nonce_s + tag
    assert len(hello_body) == 100

    # §10 stage 1: the handshake transcript and keys, identities not yet known.
    th1 = sha256(L["transcript"] + lp32(qr_bytes) + lp32(hello_body) + lp32(offer_body) + lp32(ct))
    ikm = ss_kem + ss_x + nonce_s + nonce_d
    prk1 = hkdf_extract(th1, ikm)
    k_enc_s = hkdf_expand(prk1, L["enc_s"], 32)
    k_enc_d = hkdf_expand(prk1, L["enc_d"], 32)
    k_mac_s = hkdf_expand(prk1, L["mac_s"], 32)
    k_mac_d = hkdf_expand(prk1, L["mac_d"], 32)

    # Scanner identity, signed and MACed over the chained transcript, sealed.
    id_s = id_block(idpub_s, encpub_s, user_s)
    th_s = sha256(L["th_s"] + th1 + lp32(id_s))
    sig_s = sk_s.sign(L["sig_s"] + th_s)
    mac_s = hmac256(k_mac_s, th_s)
    sealed_s = aes_gcm_seal(k_enc_s, th1, id_s + sig_s + mac_s)
    accept_body = ct + sealed_s
    assert len(accept_body) == 1568 + len(id_s) + 64 + 32 + 16

    # Displayer identity, chained onto the scanner's transcript, sealed.
    id_d = id_block(idpub_d, encpub_d, user_d)
    th_d = sha256(L["th_d"] + th_s + lp32(id_d))
    sig_d = sk_d.sign(L["sig_d"] + th_d)
    mac_d = hmac256(k_mac_d, th_d)
    sealed_d = aes_gcm_seal(k_enc_d, th_s, id_d + sig_d + mac_d)
    finish_body = sealed_d
    assert len(finish_body) == len(id_d) + 64 + 32 + 16

    # §10 stage 2: final keys bound to the whole transcript, identities included.
    prk2 = hkdf_extract(th_d, prk1)
    k_confirm_s = hkdf_expand(prk2, L["confirm_s"], 32)
    k_confirm_d = hkdf_expand(prk2, L["confirm_d"], 32)
    sas_bytes = hkdf_expand(prk2, L["sas"], 8)
    psk = hkdf_expand(prk2, L["psk"], 32)

    # The signatures really verify (the Swift/Kotlin ports check them too).
    sk_s.public_key().verify(sig_s, L["sig_s"] + th_s)
    sk_d.public_key().verify(sig_d, L["sig_d"] + th_d)

    vec = {
        "description": "Proximity pairing v1 reference vectors "
                       "(docs/security/PROXIMITY_PAIRING_QR_BLE_SPEC.md §15). "
                       "Generated by scripts/kat/gen_proximity_pairing_kat.py — do not edit by hand.",
        "inputs": {
            "sessionSecret": session_secret.hex(),
            "sessionId": session_id.hex(),
            "frameIndex": frame_index,
            "displayerMlKemPublicKey": ek_d.hex(),
            "displayerEphemeralX25519": xpk_d.hex(),
            "displayerNonce": nonce_d.hex(),
            "displayerSigningSeed": seed_d.hex(),
            "displayerSigningPublicKey": idpub_d.hex(),
            "displayerEncryptionPublicKey": encpub_d.hex(),
            "displayerUserId": user_d,
            "scannerEphemeralX25519": xpk_s.hex(),
            "scannerNonce": nonce_s.hex(),
            "mlKemCiphertext": ct.hex(),
            "scannerSigningSeed": seed_s.hex(),
            "scannerSigningPublicKey": idpub_s.hex(),
            "scannerEncryptionPublicKey": encpub_s.hex(),
            "scannerUserId": user_s,
            "kemSharedSecret": ss_kem.hex(),
            "x25519SharedSecret": ss_x.hex(),
        },
        "expected": {
            "offerBody": offer_body.hex(),
            "offerMessage": (bytes([MSG_OFFER]) + offer_body).hex(),
            "commitment": commitment.hex(),
            "frameKey0": frame_key_0.hex(),
            "frameKey": frame_key.hex(),
            "qrBytes": qr_bytes.hex(),
            "qrText": qr_text,
            "helloTag": tag.hex(),
            "helloBody": hello_body.hex(),
            "helloMessage": (bytes([MSG_HELLO]) + hello_body).hex(),
            "transcriptHash": th1.hex(),
            "prk": prk1.hex(),
            "encKeyScanner": k_enc_s.hex(),
            "encKeyDisplayer": k_enc_d.hex(),
            "macKeyScanner": k_mac_s.hex(),
            "macKeyDisplayer": k_mac_d.hex(),
            "scannerIdBlock": id_s.hex(),
            "scannerTranscriptHash": th_s.hex(),
            "signaturePayloadScanner": (L["sig_s"] + th_s).hex(),
            "signatureScanner": sig_s.hex(),
            "macScanner": mac_s.hex(),
            "sealedScanner": sealed_s.hex(),
            "acceptBody": accept_body.hex(),
            "acceptMessage": (bytes([MSG_ACCEPT]) + accept_body).hex(),
            "displayerIdBlock": id_d.hex(),
            "displayerTranscriptHash": th_d.hex(),
            "signaturePayloadDisplayer": (L["sig_d"] + th_d).hex(),
            "signatureDisplayer": sig_d.hex(),
            "macDisplayer": mac_d.hex(),
            "sealedDisplayer": sealed_d.hex(),
            "finishBody": finish_body.hex(),
            "finishMessage": (bytes([MSG_FINISH]) + finish_body).hex(),
            "finalPrk": prk2.hex(),
            "confirmKeyScanner": k_confirm_s.hex(),
            "confirmKeyDisplayer": k_confirm_d.hex(),
            "sasBytes": sas_bytes.hex(),
            "sas": sas_from_bytes(sas_bytes),
            "psk": psk.hex(),
            "pskFingerprint": sha256(psk).hex(),
            "confirmMacScanner": hmac256(k_confirm_s, L["confirmed"]).hex(),
            "confirmMacDisplayer": hmac256(k_confirm_d, L["confirmed"]).hex(),
            "confirmMessageScanner": (bytes([MSG_CONFIRM]) + hmac256(k_confirm_s, L["confirmed"])).hex(),
            "abortMessageUserRejected": bytes([MSG_ABORT, 0x01]).hex(),
            "busyMessage": bytes([MSG_BUSY]).hex(),
        },
        "userIds": {
            "valid": [u for u in VALID_USER_IDS],
            "invalid": [u for u in INVALID_USER_IDS],
        },
        "sas": [
            {"bytes": "0000000000000000", "sas": "000000"},
            {"bytes": "ffffffffffffffff", "sas": sas_from_bytes(bytes.fromhex("ffffffffffffffff"))},
            {"bytes": "00000000000f423f", "sas": "999999"},
            {"bytes": "00000000000f4240", "sas": "000000"},
            {"bytes": "0123456789abcdef", "sas": sas_from_bytes(bytes.fromhex("0123456789abcdef"))},
        ],
        "framing": [],
    }

    for msg_len, mvl in [(1, 20), (18, 20), (19, 20), (50, 20), (1925, 182), (1925, 512)]:
        msg = filler(f"frame-msg-{msg_len}", msg_len)
        vec["framing"].append({
            "message": msg.hex(),
            "maxValueLength": mvl,
            "fragments": [f.hex() for f in fragment(msg, mvl)],
        })

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                       "QAudionEngine", "Tests", "QAudionEngineTests", "Proximity",
                       "Resources", "proximity-pairing-kat.json")
    out = os.path.normpath(out)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(vec, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(f"wrote {out}")
    print(f"sas={vec['expected']['sas']} th1={th1.hex()[:16]}… psk_fp={sha256(psk).hex()[:16]}…")


if __name__ == "__main__":
    main()
