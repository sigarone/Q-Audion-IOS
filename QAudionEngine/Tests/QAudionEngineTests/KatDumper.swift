/**
 * Q-Audion iOS KAT dumper — CryptoKit-only.
 *
 * HOW TO USE
 * ----------
 * 1. Open QAudionEngine.xcodeproj (or the SPM package) in Xcode.
 * 2. Run this single test:
 *        Product > Test (Cmd-U)  — or click the diamond next to `testDumpAllVectors`.
 * 3. The test writes `/tmp/kat-vectors-ios.json`.
 * 4. Copy that file to `qaudion-desktop/test/kat/kat-vectors-ios.json`.
 * 5. Run the desktop suite: `npx vitest run test/kat`.
 *
 * All vectors are **deterministic** (fixed seeds / pinned salt + nonce) so every
 * run on every machine produces the same JSON. Any drift is a real crypto regression.
 *
 * Sections dumped
 * ---------------
 * - HKDF-SHA256 with every Q-Audion label (6 vectors)
 * - AES-256-GCM with fixed key/nonce/AAD/plaintext
 * - MessageCrypto end-to-end wire blob (HKDF-derived key + AES-GCM, pinned salt/nonce)
 * - mlKem1024, x25519, x448: empty arrays (CryptoKit lacks deterministic keygen from seed)
 */

import XCTest
import CryptoKit
import Foundation

final class KatDumper: XCTestCase {

    // MARK: - helpers

    private func toHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func toHex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { ptr in
            Data(ptr).map { String(format: "%02x", $0) }.joined()
        }
    }

    private func repeatedByte(_ byte: UInt8, count: Int) -> Data {
        Data(repeating: byte, count: count)
    }

    // MARK: - The one and only test entry-point

    func testDumpAllVectors() throws {
        var sections: [String] = []

        // ─── HKDF-SHA256 ────────────────────────────────────────────────
        let hkdfCases: [(label: String, ikm: Data, salt: Data, okmLen: Int)] = [
            ("q-audion-msg-key", repeatedByte(0xaa, count: 32), repeatedByte(0x11, count: 32), 32),
            ("q-audion-frame-key", repeatedByte(0xbb, count: 32), repeatedByte(0x22, count: 32), 32),
            ("q-audion-video-frame-key", repeatedByte(0xcc, count: 32), repeatedByte(0x33, count: 32), 32),
            ("q-audion-root-ratchet", repeatedByte(0xdd, count: 32), repeatedByte(0x44, count: 32), 32),
            ("q-audion-psk-mix", repeatedByte(0xee, count: 32), repeatedByte(0x55, count: 32), 32),
            ("qaudion-pairwise-v1", repeatedByte(0xff, count: 32), repeatedByte(0x66, count: 32), 32),
        ]

        var hkdfEntries: [String] = []
        for c in hkdfCases {
            let info = Data(c.label.utf8)
            let ikm = SymmetricKey(data: c.ikm)
            let okm = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm,
                salt: c.salt,
                info: info,
                outputByteCount: c.okmLen
            )
            let entry = """
                {\"label\":\"\(c.label)\",\"ikm\":\"\(toHex(c.ikm))\",\"salt\":\"\(toHex(c.salt))\",\"okmLen\":\(c.okmLen),\"okm\":\"\(toHex(okm))\"}
            """
            hkdfEntries.append(entry.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        sections.append("  \"hkdf\": [\n    " + hkdfEntries.joined(separator: ",\n    ") + "\n  ]")

        // ─── AES-256-GCM ────────────────────────────────────────────────
        do {
            let key = SymmetricKey(data: repeatedByte(0x00, count: 32))
            let nonce = try AES.GCM.Nonce(data: repeatedByte(0x00, count: 12))
            let aad  = Data("KAT-AAD".utf8)
            let pt   = Data("Hello Q-Audion 🔐".utf8)
            let sealed = try AES.GCM.seal(pt, using: key, nonce: nonce, authenticating: aad)

            let ct  = sealed.ciphertext
            let tag = sealed.tag

            let entry = """
            {
                  \"key\":\"\(toHex(repeatedByte(0x00, count: 32)))\",
                  \"nonce\":\"\(toHex(repeatedByte(0x00, count: 12)))\",
                  \"aad\":\"\(toHex(aad))\",
                  \"plaintext\":\"\(toHex(pt))\",
                  \"ciphertext\":\"\(toHex(Data(ct)))\",
                  \"tag\":\"\(toHex(Data(tag)))\"
                }
            """
            sections.append("  \"aesGcm\": [\n    " + entry.trimmingCharacters(in: .whitespacesAndNewlines) + "\n  ]")
        }

        // ─── MessageCrypto wire blob ─────────────────────────────────────
        do {
            let psk   = repeatedByte(0xaa, count: 32)
            let salt  = repeatedByte(0xbb, count: 32)
            let nonce = try AES.GCM.Nonce(data: repeatedByte(0xcc, count: 12))

            let sender    = "alice"
            let recipient = "bob"
            let msgId     = "00000000-0000-0000-0000-000000000001"
            let aad       = Data("msg:\(sender):\(recipient):\(msgId)".utf8)
            let pt        = Data("hello android!".utf8)

            // Derive message key: HKDF-SHA256(psk, salt, info="q-audion-msg-key") → 32 bytes
            let msgKey = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: psk),
                salt: salt,
                info: Data("q-audion-msg-key".utf8),
                outputByteCount: 32
            )

            let sealed = try AES.GCM.seal(pt, using: msgKey, nonce: nonce, authenticating: aad)

            // wire = salt(32) || nonce(12) || ciphertext || tag(16)
            var wire = Data()
            wire.append(salt)
            wire.append(repeatedByte(0xcc, count: 12))  // nonce raw bytes
            wire.append(contentsOf: sealed.ciphertext)
            wire.append(contentsOf: sealed.tag)

            let entry = """
            {
                  \"senderId\":\"\(sender)\",
                  \"recipientId\":\"\(recipient)\",
                  \"msgId\":\"\(msgId)\",
                  \"psk\":\"\(toHex(psk))\",
                  \"plaintext\":\"hello android!\",
                  \"wireBlob\":\"\(toHex(wire))\"
                }
            """
            sections.append("  \"messageCrypto\": [\n    " + entry.trimmingCharacters(in: .whitespacesAndNewlines) + "\n  ]")
        }

        // ─── Empty stubs (no deterministic keygen in CryptoKit) ──────────
        sections.append("  \"mlKem1024\": []")
        sections.append("  \"x25519\": []")
        sections.append("  \"x448\": []")

        // ─── Assemble JSON ───────────────────────────────────────────────
        let json = """
        {
          "schema": 1,
          "generator": "Q-Audion iOS KatDumper",
        \(sections.joined(separator: ",\n"))
        }
        """

        let outURL = URL(fileURLWithPath: "/tmp/kat-vectors-ios.json")
        try json.data(using: .utf8)!.write(to: outURL)
        print("[KatDumper] wrote \(outURL.path)")

        // Sanity: parse it back
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: outURL)) as! [String: Any]
        XCTAssertEqual(parsed["schema"] as? Int, 1)
        XCTAssertEqual((parsed["hkdf"] as? [[String: Any]])?.count, 6)
        XCTAssertEqual((parsed["aesGcm"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((parsed["messageCrypto"] as? [[String: Any]])?.count, 1)
    }
}
