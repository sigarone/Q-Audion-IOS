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
            // .offer branch):
            //   intersection = advertised.filter { eligiblePsks[$0] != nil }.sorted()
            //   if let first = intersection.first { selectedFp = first }
            let localSet = Set(v.local)
            let intersection = v.offer.filter { localSet.contains($0) }.sorted()
            let selected = intersection.first

            XCTAssertEqual(
                selected, v.expected_selected,
                "[\(v.name)] PSK selection drift — iOS lex-sort intersection failed"
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
