import Foundation
import CryptoKit

/// Crockford Base32 activation-code format, design doc §5.1 — a
/// byte-for-byte Swift port of the Go reference implementation
/// (`bcrypto-server/cmd/bcrypto-lite/entitlements_code_format.go`), the
/// SAME algorithm Android's Kotlin port implements
/// (`core/core-data/.../entitlements/ActivationCodeFormat.kt`, Android's
/// own Task 5). Pure functions only, no network/Keychain dependency — the
/// cheap, instant, OFFLINE pre-check design doc §5.1 calls for, run before
/// `UpgradeSheet` ever calls `POST /api/v1/entitlements/redeem`.
///
/// `ActivationCodeTests` pins this against the SAME known-answer vectors
/// the Go file's own `TestChecksumVectors_KAT` hardcodes (also ported
/// verbatim into Android's `ActivationCodeFormatTest.kt`) — design doc
/// §13's "the same vectors implemented in Go, Kotlin, Swift and TypeScript
/// from one shared KAT file" cross-platform parity requirement. Do not
/// hand-derive new expected values in the test file — if the format ever
/// changes, the Go table changes first and the others are re-copied from
/// it, otherwise this stops being a genuine cross-platform check.

/// Excludes I, L, O, U so a spoken or handwritten code survives without
/// confusion (design doc §5.1) — identical to the Go `crockfordAlphabet`
/// and Kotlin's `CROCKFORD_ALPHABET`.
private let crockfordAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

private let activationCodePrefixLen = 3
private let activationCodePayloadLen = 15 // 3 groups of 5, 75 bits of entropy at 5 bits/char
private let activationCodeChecksumLen = 2

/// Returns the 2-character checksum: the first 10 bits of
/// `SHA-256(prefix + payload)`, re-encoded in the Crockford alphabet (10
/// bits = 2 Crockford chars at 5 bits each). Mirrors the Go
/// `computeActivationCodeChecksum` / Kotlin `computeActivationCodeChecksum`
/// bit-for-bit — SHA-256 chosen specifically because it behaves
/// identically across Go, Kotlin, Swift and TypeScript with zero
/// reimplementation risk (design doc §5.1).
public func computeActivationCodeChecksum(_ prefix: String, _ payload: String) -> String {
    let digest = SHA256.hash(data: Data((prefix + payload).utf8))
    let bytes = Array(digest)
    let b0 = Int(bytes[0])
    let b1 = Int(bytes[1])
    // First 10 bits: byte 0 (8 bits) + top 2 bits of byte 1.
    let first5 = b0 >> 3                          // top 5 bits of byte 0
    let second5 = ((b0 & 0x07) << 2) | (b1 >> 6)   // bottom 3 bits of byte 0 + top 2 bits of byte 1
    return String(crockfordAlphabet[first5]) + String(crockfordAlphabet[second5])
}

func formatActivationCode(_ prefix: String, _ payload: String, _ checksum: String) -> String {
    let chars = Array(payload)
    let g1 = String(chars[0..<5])
    let g2 = String(chars[5..<10])
    let g3 = String(chars[10..<15])
    return "\(prefix)-\(g1)-\(g2)-\(g3)-\(checksum)"
}

/// Strips hyphens/whitespace and upper-cases, so a code pasted with
/// different spacing or case still matches — same contract as the Go
/// `normalizeActivationCode` / Kotlin `normalizeActivationCode`. Returns
/// `""` (caller treats as invalid-shape) if what remains after stripping
/// non-alphabet characters isn't exactly prefix+payload+checksum long.
func normalizeActivationCode(_ raw: String) -> String {
    let upper = raw.uppercased()
    let flat = String(upper.filter { crockfordAlphabet.contains($0) })
    let expectedLen = activationCodePrefixLen + activationCodePayloadLen + activationCodeChecksumLen
    guard flat.count == expectedLen else { return "" }
    let chars = Array(flat)
    let prefix = String(chars[0..<activationCodePrefixLen])
    let payload = String(chars[activationCodePrefixLen..<(activationCodePrefixLen + activationCodePayloadLen)])
    let checksum = String(chars[(activationCodePrefixLen + activationCodePayloadLen)...])
    return formatActivationCode(prefix, payload, checksum)
}

/// Live "as you type" formatter for a code-entry text field's `onChange` —
/// unlike `normalizeActivationCode` (which returns `""` unless the input is
/// already exactly the right length, so it's only useful as a final-submit
/// check), this uppercases and re-inserts dashes at every keystroke, on
/// however many characters have been typed so far, truncating at the code's
/// fixed total length so the field can never grow past QA1-XXXXX-XXXXX-XXXXX-CC.
/// Bug found live 2026-08-18: every code-entry field required the user to
/// type the dashes and capitalization exactly themselves with zero help.
public func liveFormatActivationCodeInput(_ raw: String) -> String {
    let upper = raw.uppercased()
    let maxLen = activationCodePrefixLen + activationCodePayloadLen + activationCodeChecksumLen
    let flat = String(upper.filter { crockfordAlphabet.contains($0) }.prefix(maxLen))
    let dashBefore: Set<Int> = [
        activationCodePrefixLen,
        activationCodePrefixLen + 5,
        activationCodePrefixLen + 10,
        activationCodePrefixLen + activationCodePayloadLen,
    ]
    var result = ""
    for (i, c) in flat.enumerated() {
        if dashBefore.contains(i) { result.append("-") }
        result.append(c)
    }
    return result
}

/// Normalizes `raw` and checks its embedded checksum without touching the
/// network — the cheap, instant, LOCAL pre-check design doc §5.1 calls
/// for, run before `POST /api/v1/entitlements/redeem` is ever called.
/// Mirrors the Go `VerifyActivationCodeChecksum` / Kotlin
/// `verifyActivationCodeChecksum` exactly — same normalization, same
/// checksum recompute-and-compare. A client-side pass is a UX courtesy,
/// not the security boundary — the server re-checks it as its own first
/// gate (`handleEntitlementsRedeem`, design doc §5.1).
public func verifyActivationCodeChecksum(_ raw: String) -> Bool {
    let canon = normalizeActivationCode(raw)
    guard !canon.isEmpty else { return false }
    let parts = canon.components(separatedBy: "-")
    guard parts.count == 5 else { return false }
    let prefix = parts[0]
    let payload = parts[1] + parts[2] + parts[3]
    let want = computeActivationCodeChecksum(prefix, payload)
    return parts[4] == want
}
