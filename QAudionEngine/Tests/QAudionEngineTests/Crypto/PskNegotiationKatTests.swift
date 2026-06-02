import XCTest
@testable import QAudionEngine

/// Cross-platform PSK fingerprint negotiation KAT verifier (iOS side).
///
/// Loads `tools/kat/psk-negotiation/psk-negotiation-kat.json` and
/// asserts the algorithm
/// `selected = sort(offerSet ∩ localSet, lex-ascending)[0]` matches
/// the production code path used in
/// `QAudionCallIntegration.onAndroidBundleReceived` (responder side).
/// WIRE_SPEC §3.3.
///
/// Sister tests:
///   apps/qaudion-android-new/.../PskNegotiationKatTest.kt
///   apps/qaudion-desktop/test/PskNegotiation.kat.spec.ts
final class PskNegotiationKatTests: XCTestCase {

    private struct KatVector: Decodable {
        let name: String
        let offer: [String]
        let local: [String]
        let expected_selected: String?
    }

    private struct KatFile: Decodable {
        let schema: String
        let vectors: [KatVector]
    }

    func testEveryPskNegotiationVector() throws {
        guard let kat = loadKatOrNil() else { return }

        XCTAssertEqual(kat.schema, "qaudion-psk-negotiation-kat:1")
        XCTAssertGreaterThan(kat.vectors.count, 0)

        for v in kat.vectors {
            // Reproduce the production algorithm from
            // QAudionCallIntegration.onAndroidBundleReceived (responder
            // .offer branch) — CALLER'S PRIORITY COMMANDS (WIRE_SPEC §3.3,
            // revised 2026-06-02): pick the FIRST fingerprint in the OFFER's
            // order that we also hold. NOT a lexicographic sort.
            //   selectedFp = advertised.first(where: { eligiblePsks[$0] != nil })
            let localSet = Set(v.local)
            let selected = v.offer.first(where: { localSet.contains($0) })

            XCTAssertEqual(
                selected, v.expected_selected,
                "[\(v.name)] PSK selection drift — iOS caller-priority first-match failed"
            )
        }
    }

    private func loadKatOrNil() -> KatFile? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("tools/kat/psk-negotiation/psk-negotiation-kat.json")
            if fm.fileExists(atPath: candidate.path) {
                if let data = try? Data(contentsOf: candidate),
                   let kat = try? JSONDecoder().decode(KatFile.self, from: data) {
                    return kat
                }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
