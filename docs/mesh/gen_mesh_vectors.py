#!/usr/bin/env python3
"""Deterministic generator for the BLE mesh link-layer and wire test vectors.

Produces mesh-vectors.json next to this script (or at the path given as the
first argument). Every value is derived from fixed inputs: running the script
twice must produce byte-identical output.

Covers, per MESH_LINK_SPEC.md:
  - node id derivation (SHA-256 of a raw Ed25519 public key, first 8 bytes)
  - MeshPacket header encoding and decode rejections
  - ANNOUNCE discovery-cipher key, canonical JSON, AES-256-GCM with a fixed nonce
  - sealed shell, chat envelope and receipt canonical JSON (+ accepted variants)
  - associated-data strings
  - link-frame splitting for several per-link value limits, and reassembly cases
  - relay probability table

Requires the `cryptography` package (AES-GCM only). HKDF and SHA-256 use the
standard library.
"""

import hashlib
import hmac
import json
import struct
import sys
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

SPEC_VERSION = "mesh-link-spec/1"

# --------------------------------------------------------------------------
# Constants (MESH_LINK_SPEC.md section 2 and 6)
# --------------------------------------------------------------------------
SERVICE_UUID = "b7c1a5e0-9d3a-4f6b-8a21-0d1e2f3a4b01"
CHAR_UUID = "b7c1a5e0-9d3a-4f6b-8a21-0d1e2f3a4b02"
CCCD_UUID = "00002902-0000-1000-8000-00805f9b34fb"
WIRE_VERSION = 1
FLAG_HAS_TTL = 0x01
FLAG_HAS_ROUTE = 0x02
MAX_PAYLOAD = 16 * 1024
NODE_BYTES = 8
FRAME_HEADER = 4
MAX_FRAMES = 255
DEFAULT_TTL = 5
MAX_PACKET_BYTES = 1 + 1 + 8 + 8 + 1 + 1 + 1 + 255 * 8 + 8 + 4 + MAX_PAYLOAD

TYPES = {"DATA": 0x01, "FRAGMENT": 0x02, "ANNOUNCE": 0x03, "ACK": 0x04, "RECEIPT": 0x05}
BROADCAST = "ff" * NODE_BYTES

DISCOVERY_IKM = "Q-Audion-Mesh-Discovery-Shared-Seed-v1"
DISCOVERY_SALT = "q-audion-mesh-discovery-salt-v1"
DISCOVERY_INFO = "q-audion-mesh-discovery-v1"


def hx(b: bytes) -> str:
    return b.hex()


# --------------------------------------------------------------------------
# Primitives
# --------------------------------------------------------------------------
def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, t, counter = b"", b"", 1
    while len(out) < length:
        t = hmac.new(prk, t + info + bytes([counter]), hashlib.sha256).digest()
        out += t
        counter += 1
    return out[:length]


def node_id_from_key(raw: bytes) -> str:
    return hashlib.sha256(raw).digest()[:NODE_BYTES].hex()


def canonical_json(obj) -> bytes:
    # Field order is the dict insertion order; no whitespace; UTF-8; "/" not escaped.
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def encode_packet(ptype: int, sender: str, recipient: str, ttl, route, ts: int, payload: bytes,
                  version: int = WIRE_VERSION) -> bytes:
    flags = 0
    if ttl is not None:
        flags |= FLAG_HAS_TTL
    if route:
        flags |= FLAG_HAS_ROUTE
    out = bytearray()
    out += bytes([version, ptype])
    out += bytes.fromhex(sender)
    out += bytes.fromhex(recipient)
    out += bytes([flags])
    if ttl is not None:
        out += bytes([ttl])
    if route:
        out += bytes([len(route)])
        for hop in route:
            out += bytes.fromhex(hop)
    out += struct.pack(">q", ts)
    out += struct.pack(">I", len(payload))
    out += payload
    return bytes(out)


def decode_packet(b: bytes):
    """Reference decoder with the strict rules of MESH_LINK_SPEC.md section 7.2.

    Returns (dict, None) on success or (None, reason) on rejection.
    """
    p = 0

    def take(n):
        nonlocal p
        if n < 0 or p + n > len(b):
            raise ValueError("truncated")
        v = b[p:p + n]
        p += n
        return v

    try:
        version = take(1)[0]
        if version != WIRE_VERSION:
            return None, "unsupported_version"
        ptype = take(1)[0]
        if ptype not in TYPES.values():
            return None, "unknown_type"
        sender = take(8).hex()
        recipient = take(8).hex()
        flags = take(1)[0]
        if flags & ~(FLAG_HAS_TTL | FLAG_HAS_ROUTE):
            return None, "unknown_flag_bits"
        ttl = take(1)[0] if flags & FLAG_HAS_TTL else None
        route = []
        if flags & FLAG_HAS_ROUTE:
            n = take(1)[0]
            if n == 0:
                return None, "empty_route_with_flag"
            route = [take(8).hex() for _ in range(n)]
        ts = struct.unpack(">q", take(8))[0]
        plen = struct.unpack(">I", take(4))[0]
        if plen > MAX_PAYLOAD:
            return None, "payload_too_large"
        payload = take(plen)
        if p != len(b):
            return None, "trailing_bytes"
    except ValueError:
        return None, "truncated"
    return {
        "version": version, "type": ptype, "senderId": sender, "recipientId": recipient,
        "ttl": ttl, "sourceRoute": route, "timestampMs": ts, "payloadHex": payload.hex(),
    }, None


def split_frames(packet: bytes, att_value_max: int, set_id: int):
    chunk = att_value_max - FRAME_HEADER
    if chunk < 1:
        return None, "link_too_small"
    total = max(1, -(-len(packet) // chunk))
    if total > MAX_FRAMES:
        return None, "frame_count_overflow"
    frames = []
    for i in range(total):
        part = packet[i * chunk:(i + 1) * chunk]
        frames.append(struct.pack(">HBB", set_id, i, total) + part)
    return frames, None


class Reassembler:
    """Reference receiver for one link (MESH_LINK_SPEC.md section 6.3), time-free."""

    def __init__(self):
        self.sets = {}

    def offer(self, frame: bytes):
        if len(frame) < FRAME_HEADER + 1:
            return "malformed:short_frame", None
        set_id, index, total = struct.unpack(">HBB", frame[:4])
        chunk = frame[4:]
        if total == 0 or index >= total:
            return "malformed:bad_header", None
        if total == 1:
            return "complete", chunk
        cur = self.sets.get(set_id)
        if cur is not None and cur["total"] != total:
            del self.sets[set_id]
            return "malformed:total_mismatch", None
        if cur is None:
            cur = {"total": total, "chunks": {}}
            self.sets[set_id] = cur
        if index in cur["chunks"]:
            return "duplicate_ignored", None
        cur["chunks"][index] = chunk
        if sum(len(c) for c in cur["chunks"].values()) > MAX_PACKET_BYTES:
            del self.sets[set_id]
            return "malformed:set_too_large", None
        if len(cur["chunks"]) == total:
            del self.sets[set_id]
            return "complete", b"".join(cur["chunks"][i] for i in range(total))
        return "pending", None


def relay_probability(peers: int, ttl: int, max_ttl: int = DEFAULT_TTL) -> float:
    if peers <= 4:
        return 1.0
    frac = min(max(ttl / max_ttl, 0.0), 1.0)
    damping = 4 / peers
    return min(max(damping + frac * (1.0 - damping), 0.15), 1.0)


# --------------------------------------------------------------------------
# Fixed inputs
# --------------------------------------------------------------------------
# RFC 8032 section 7.1 test public keys (raw 32-byte Ed25519).
IDENTITY_KEYS = [
    ("rfc8032-test1", "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"),
    ("rfc8032-test2", "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"),
    ("rfc8032-test3", "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025"),
]
NODE_A = node_id_from_key(bytes.fromhex(IDENTITY_KEYS[0][1]))
NODE_B = node_id_from_key(bytes.fromhex(IDENTITY_KEYS[1][1]))
NODE_C = node_id_from_key(bytes.fromhex(IDENTITY_KEYS[2][1]))
TS = 1760000000000
USER_A = "11111111-2222-4333-8444-555555555555"
USER_B = "66666666-7777-4888-9999-aaaaaaaaaaaa"
MSG_ID = "0f1e2d3c-4b5a-4968-8796-a5b4c3d2e1f0"
RECEIPT_ID = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
CONV_ID = "c0c0c0c0-d1d1-4e2e-8f3f-a4a4a4a4a4a4"


def fake_sealed_b64(n: int) -> str:
    # Opaque placeholder for the ratchet output: NOT real ciphertext. Only the
    # size and the base64 alphabet matter at this layer.
    import base64
    raw = hashlib.sha256(b"mesh-vector-sealed").digest()
    buf = (raw * (n // len(raw) + 1))[:n]
    return base64.b64encode(buf).decode("ascii")


def build():
    v = {"spec": SPEC_VERSION, "generator": "gen_mesh_vectors.py"}
    v["constants"] = {
        "serviceUuid": SERVICE_UUID, "characteristicUuid": CHAR_UUID, "cccdUuid": CCCD_UUID,
        "wireVersion": WIRE_VERSION, "nodeIdBytes": NODE_BYTES, "broadcastNodeId": BROADCAST,
        "maxPayloadBytes": MAX_PAYLOAD, "maxPacketBytes": MAX_PACKET_BYTES,
        "frameHeaderBytes": FRAME_HEADER, "maxFramesPerSet": MAX_FRAMES, "defaultTtl": DEFAULT_TTL,
        "packetTypes": TYPES,
    }

    # ---- node ids ----
    v["nodeIds"] = [
        {"name": name, "identityKeyHex": key, "nodeIdHex": node_id_from_key(bytes.fromhex(key))}
        for name, key in IDENTITY_KEYS
    ]

    # ---- packet headers ----
    cases = [
        ("announce_broadcast_no_ttl", TYPES["ANNOUNCE"], NODE_A, BROADCAST, None, [], TS, bytes(range(8))),
        ("data_ttl5", TYPES["DATA"], NODE_A, NODE_B, 5, [], TS + 1, b"\xde\xad\xbe\xef"),
        ("data_ttl0_relayed", TYPES["DATA"], NODE_A, NODE_B, 0, [], TS + 2, b"\x00"),
        ("data_source_route_2_hops", TYPES["DATA"], NODE_A, NODE_B, 4, [NODE_C, NODE_B], TS + 3, b"xyz"),
        ("receipt_ttl5_empty_payload", TYPES["RECEIPT"], NODE_B, NODE_A, 5, [], TS + 4, b""),
        ("negative_timestamp", TYPES["DATA"], NODE_A, NODE_B, 1, [], -1, b"\x01\x02"),
    ]
    headers = []
    for name, t, s, r, ttl, route, ts, payload in cases:
        enc = encode_packet(t, s, r, ttl, route, ts, payload)
        dec, err = decode_packet(enc)
        assert err is None, (name, err)
        headers.append({
            "name": name,
            "fields": {"version": WIRE_VERSION, "type": t, "senderId": s, "recipientId": r, "ttl": ttl,
                       "sourceRoute": route, "timestampMs": ts, "payloadHex": payload.hex()},
            "encodedHex": enc.hex(), "encodedLength": len(enc),
        })
    v["packetHeaders"] = headers

    good = bytes.fromhex(headers[1]["encodedHex"])
    neg = []

    def negcase(name, b, reason):
        dec, err = decode_packet(b)
        assert dec is None and err == reason, (name, err)
        neg.append({"name": name, "hex": b.hex(), "expect": "reject", "reason": reason})

    negcase("empty", b"", "truncated")
    negcase("three_bytes", b"\x01\x01\xff", "truncated")
    negcase("version_0", b"\x00" + good[1:], "unsupported_version")
    negcase("version_2", b"\x02" + good[1:], "unsupported_version")
    negcase("unknown_type_0x06", good[:1] + b"\x06" + good[2:], "unknown_type")
    negcase("unknown_flag_bit_0x04", good[:18] + bytes([good[18] | 0x04]) + good[19:], "unknown_flag_bits")
    negcase("truncated_payload", good[:-1], "truncated")
    negcase("trailing_byte", good + b"\x00", "trailing_bytes")
    negcase("route_flag_with_zero_hops",
            encode_packet(TYPES["DATA"], NODE_A, NODE_B, None, [], TS, b"")[:18] + b"\x02\x00"
            + struct.pack(">q", TS) + struct.pack(">I", 0), "empty_route_with_flag")
    big = encode_packet(TYPES["DATA"], NODE_A, NODE_B, 5, [], TS, b"")
    big = big[:-4] + struct.pack(">I", MAX_PAYLOAD + 1)
    negcase("payload_length_over_cap", big, "payload_too_large")
    v["packetDecodeNegative"] = neg

    # ---- discovery cipher + ANNOUNCE ----
    key = hkdf_sha256(DISCOVERY_IKM.encode(), DISCOVERY_SALT.encode(), DISCOVERY_INFO.encode(), 32)
    v["discoveryCipher"] = {
        "kdf": "HKDF-SHA256", "ikmUtf8": DISCOVERY_IKM, "saltUtf8": DISCOVERY_SALT, "infoUtf8": DISCOVERY_INFO,
        "keyHex": key.hex(), "aead": "AES-256-GCM", "nonceBytes": 12, "tagBytes": 16, "aad": "none",
        "wireLayout": "nonce(12) || ciphertext || tag(16)",
    }
    aes = AESGCM(key)
    announces = []
    ann_cases = [
        ("no_neighbors", {"v": 1, "node": NODE_A, "fp": NODE_A, "nbrs": []}, bytes(range(12))),
        ("two_neighbors", {"v": 1, "node": NODE_B, "fp": NODE_B, "nbrs": [NODE_A, NODE_C]},
         bytes(range(12, 24))),
        ("ten_neighbors", {"v": 1, "node": NODE_C, "fp": NODE_C,
                           "nbrs": [hashlib.sha256(bytes([i])).digest()[:8].hex() for i in range(10)]},
         bytes([0xA5] * 12)),
    ]
    for name, obj, nonce in ann_cases:
        pt = canonical_json(obj)
        ct = aes.encrypt(nonce, pt, None)
        wire = nonce + ct
        assert aes.decrypt(wire[:12], wire[12:], None) == pt
        pkt = encode_packet(TYPES["ANNOUNCE"], obj["node"], BROADCAST, None, [], TS, wire)
        announces.append({
            "name": name, "fields": obj, "canonicalJson": pt.decode("utf-8"), "canonicalJsonHex": pt.hex(),
            "nonceHex": nonce.hex(), "wireHex": wire.hex(), "wireLength": len(wire),
            "packetTimestampMs": TS, "packetHex": pkt.hex(), "packetLength": len(pkt),
        })
    v["announce"] = announces

    tampered = bytearray(bytes.fromhex(announces[0]["wireHex"]))
    tampered[-1] ^= 0x01
    v["announceDecryptNegative"] = [
        {"name": "tag_bit_flip", "wireHex": bytes(tampered).hex(), "expect": "reject"},
        {"name": "shorter_than_nonce_plus_tag", "wireHex": bytes(27).hex(), "expect": "reject"},
    ]
    v["announceJsonAccept"] = [
        {"name": "hint_absent", "json": '{"v":1,"node":"%s","fp":"%s","nbrs":[]}' % (NODE_A, NODE_A),
         "expect": {"v": 1, "node": NODE_A, "fp": NODE_A, "hint": None, "nbrs": []}},
        {"name": "hint_null", "json": '{"v":1,"node":"%s","fp":"%s","hint":null,"nbrs":[]}' % (NODE_A, NODE_A),
         "expect": {"v": 1, "node": NODE_A, "fp": NODE_A, "hint": None, "nbrs": []}},
        {"name": "hint_string_reordered_keys",
         "json": '{"nbrs":["%s"],"hint":"x","fp":"%s","node":"%s","v":1}' % (NODE_B, NODE_A, NODE_A),
         "expect": {"v": 1, "node": NODE_A, "fp": NODE_A, "hint": "x", "nbrs": [NODE_B]}},
        {"name": "unknown_key_ignored",
         "json": '{"v":1,"node":"%s","fp":"%s","nbrs":[],"future":7}' % (NODE_A, NODE_A),
         "expect": {"v": 1, "node": NODE_A, "fp": NODE_A, "hint": None, "nbrs": []}},
        {"name": "nbrs_absent_means_empty", "json": '{"v":1,"node":"%s","fp":"%s"}' % (NODE_A, NODE_A),
         "expect": {"v": 1, "node": NODE_A, "fp": NODE_A, "hint": None, "nbrs": []}},
    ]
    v["announceJsonReject"] = [
        {"name": "v_absent", "json": '{"node":"%s","fp":"%s","nbrs":[]}' % (NODE_A, NODE_A)},
        {"name": "v_2", "json": '{"v":2,"node":"%s","fp":"%s","nbrs":[]}' % (NODE_A, NODE_A)},
        {"name": "node_uppercase", "json": '{"v":1,"node":"%s","fp":"%s","nbrs":[]}' % (NODE_A.upper(), NODE_A)},
        {"name": "node_short", "json": '{"v":1,"node":"abcd","fp":"%s","nbrs":[]}' % NODE_A},
        {"name": "fp_absent", "json": '{"v":1,"node":"%s","nbrs":[]}' % NODE_A},
        {"name": "not_json", "json": "v=1"},
    ]

    # ---- shell / envelope / receipt ----
    body = 'Ciao "mesh" / café \U0001F600\nline2'
    env = {"v": 2, "s": USER_A, "r": USER_B, "c": MSG_ID, "conv": CONV_ID, "b": body, "ts": TS,
           "sn": NODE_A, "rn": NODE_B}
    env_bytes = canonical_json(env)
    rcpt = {"v": 2, "s": USER_B, "r": USER_A, "c": RECEIPT_ID, "m": MSG_ID, "k": "d", "ts": TS + 500,
            "sn": NODE_B, "rn": NODE_A}
    rcpt_bytes = canonical_json(rcpt)
    sealed = fake_sealed_b64(300)
    shell = {"c": MSG_ID, "e": sealed}
    shell_bytes = canonical_json(shell)
    rshell = {"c": RECEIPT_ID, "e": fake_sealed_b64(180)}
    rshell_bytes = canonical_json(rshell)
    v["envelope"] = {
        "fieldOrder": list(env.keys()), "fields": env, "canonicalJson": env_bytes.decode("utf-8"),
        "canonicalJsonHex": env_bytes.hex(),
        "acceptedVariants": [
            {"name": "slash_escaped", "json": env_bytes.decode("utf-8").replace("/", "\\/")},
            {"name": "ts_last_order",
             "json": canonical_json({k: env[k] for k in ["v", "s", "r", "c", "conv", "b", "sn", "rn", "ts"]}).decode()},
            {"name": "unicode_escaped_e_acute", "json": env_bytes.decode("utf-8").replace("é", "\\u00e9")},
        ],
        "reject": [
            {"name": "v_1", "json": canonical_json(dict(env, v=1)).decode()},
            {"name": "rn_absent", "json": canonical_json({k: env[k] for k in env if k != "rn"}).decode()},
        ],
    }
    v["receipt"] = {
        "fieldOrder": list(rcpt.keys()), "fields": rcpt, "canonicalJson": rcpt_bytes.decode("utf-8"),
        "canonicalJsonHex": rcpt_bytes.hex(), "kinds": {"delivered": "d", "read": "r"},
        "reject": [
            {"name": "kind_x", "json": canonical_json(dict(rcpt, k="x")).decode()},
            {"name": "v_1", "json": canonical_json(dict(rcpt, v=1)).decode()},
        ],
    }
    v["shell"] = [
        {"name": "message_shell", "fields": shell, "canonicalJson": shell_bytes.decode(),
         "canonicalJsonHex": shell_bytes.hex(), "note": "e is an opaque placeholder, not real ratchet output"},
        {"name": "receipt_shell", "fields": rshell, "canonicalJson": rshell_bytes.decode(),
         "canonicalJsonHex": rshell_bytes.hex(), "note": "e is an opaque placeholder, not real ratchet output"},
    ]

    # ---- AAD ----
    def aad(version, t, s, r):
        return "mesh:v%d:%d:%s:%s" % (version, t & 0xFF, s, r)

    v["aad"] = [
        {"name": n, "version": 1, "type": t, "senderId": s, "recipientId": r, "aadUtf8": aad(1, t, s, r),
         "aadHex": aad(1, t, s, r).encode().hex()}
        for n, t, s, r in [
            ("data_a_to_b", TYPES["DATA"], NODE_A, NODE_B),
            ("receipt_b_to_a", TYPES["RECEIPT"], NODE_B, NODE_A),
            ("hypothetical_type_0x80_unsigned", 0x80, NODE_A, NODE_B),
        ]
    ]

    # ---- frames ----
    data_pkt = encode_packet(TYPES["DATA"], NODE_A, NODE_B, 5, [], TS, shell_bytes)
    ann_pkt = bytes.fromhex(announces[1]["packetHex"])
    frame_sets = []
    set_id = 0x1234
    for pname, pkt in [("data_message", data_pkt), ("announce_two_neighbors", ann_pkt)]:
        for att in (20, 182, 244, 509):
            frames, err = split_frames(pkt, att, set_id)
            assert err is None
            r = Reassembler()
            res = None
            for f in frames:
                st, out = r.offer(f)
                if st == "complete":
                    res = out
            assert res == pkt
            frame_sets.append({
                "packet": pname, "packetHex": pkt.hex(), "packetLength": len(pkt), "setId": set_id,
                "attValueMax": att, "attMtu": att + 3, "chunkBytes": att - FRAME_HEADER,
                "frameCount": len(frames), "framesHex": [f.hex() for f in frames],
            })
            set_id = (set_id + 0x0101) & 0xFFFF
    v["frames"] = frame_sets

    overflow_pkt = encode_packet(TYPES["DATA"], NODE_A, NODE_B, 5, [], TS, bytes(MAX_PAYLOAD))
    _, err = split_frames(overflow_pkt, 20, 1)
    _, err2 = split_frames(overflow_pkt, 182, 1)
    v["frameLimits"] = [
        {"name": "max_payload_at_att_20", "packetLength": len(overflow_pkt), "attValueMax": 20,
         "expect": err, "framesNeeded": -(-len(overflow_pkt) // 16)},
        {"name": "max_payload_at_att_182", "packetLength": len(overflow_pkt), "attValueMax": 182,
         "expect": err2 or "ok", "framesNeeded": -(-len(overflow_pkt) // 178)},
        {"name": "att_value_max_4_unusable", "attValueMax": 4, "expect": split_frames(b"x", 4, 1)[1]},
        {"name": "largest_packet_at_att_20", "attValueMax": 20, "maxPacketLength": 255 * 16},
    ]

    # ---- reassembly scenarios (one link) ----
    base = split_frames(data_pkt, 182, 0x0A0B)[0]
    other = split_frames(ann_pkt, 20, 0x0C0D)[0]
    scen = []

    def run(name, frames, expect_hex=None, expect_status=None):
        r = Reassembler()
        statuses, done = [], []
        for f in frames:
            st, out = r.offer(f)
            statuses.append(st)
            if st == "complete":
                done.append(out.hex())
        scen.append({"name": name, "framesHex": [f.hex() for f in frames], "statuses": statuses,
                     "completedPacketsHex": done, "pendingSetsAtEnd": len(r.sets)})

    run("in_order", base)
    run("reverse_order", list(reversed(base)))
    run("duplicate_frame_ignored", [base[0], base[0]] + base[1:])
    run("missing_middle_frame_stays_pending", [base[0]] + base[2:])
    interleaved = []
    for i in range(max(len(base), len(other))):
        if i < len(base):
            interleaved.append(base[i])
        if i < len(other):
            interleaved.append(other[i])
    run("two_sets_interleaved", interleaved)
    bad_total = bytearray(base[1])
    bad_total[3] = (bad_total[3] + 1) & 0xFF
    run("total_mismatch_discards_set", [base[0], bytes(bad_total)])
    run("index_ge_total", [bytes.fromhex("0001030341")])
    run("total_zero", [bytes.fromhex("0001000041")])
    run("header_only_frame", [bytes.fromhex("00010001")])
    v["reassembly"] = scen

    # ---- relay probability ----
    v["relayProbability"] = [
        {"visiblePeers": p, "ttl": t, "probability": round(relay_probability(p, t), 12)}
        for p in (1, 4, 5, 8, 20, 100) for t in (5, 3, 1, 0)
    ]
    return v


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("mesh-vectors.json")
    data = json.dumps(build(), ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    out.write_bytes(data.encode("utf-8"))
    print("%s sha256=%s" % (out, hashlib.sha256(data.encode("utf-8")).hexdigest()))


if __name__ == "__main__":
    main()
