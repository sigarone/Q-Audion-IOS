import XCTest
@testable import QAudionEngine

// This file's Decodable structs mirror KAT JSON fixture keys verbatim
// (camelCase, snake_case and the upper-case "N", no CodingKeys) — renaming would
// silently break decoding against the shared cross-platform fixture.
// swiftlint:disable identifier_name

/// Cross-platform KAT for `AssuranceState.decide(...)`.
///
/// Loads `tools/kat/assurance-state/assurance-state-kat.json`, a byte copy of the file the
/// Android and Desktop ports run, and drives every vector through `AssuranceState.decide`.
///
/// The vectors name `peerAdvertisedRoles`: the roles the peer advertised for keys this side
/// also holds. This port's `decide` takes the resolved Boolean `nfcConfirmed` instead (see
/// `AssuranceState.resolveNfcConfirmed`), so a vector's mutual-presence input maps to it: some
/// role of that set is a presence role (NFC tap, QR + Bluetooth proximity). Everything else is
/// passed through unchanged.
///
/// The file is read from the checkout and a missing file FAILS, it never skips.
final class AssuranceStateKatTests: XCTestCase {

    private struct Inputs: Decodable {
        let peerSupportsMix: Bool
        let N: Int
        let mixRoles: [String]
        let peerAdvertisedRoles: [Int]
        let expectedNfc: Bool
        let kcStatus: String
        let sigOk: Bool
        let nfcBound: Bool
        let witnessOk: Bool
        let floorRecorded: Bool
        let mediaDwellMs: Int
    }

    private struct StateVector: Decodable {
        let comment: String
        let inputs: Inputs
        let expectedState: String
    }

    private struct FlipVector: Decodable {
        let resultingInputs: Inputs
        let expectedState: String
    }

    private struct CompoundVector: Decodable {
        let note: String
        let resultingInputs: Inputs
        let expectedState: String
    }

    private struct Exhaustiveness: Decodable {
        let s2_baseline: Inputs
        let s2_baseline_expected_state: String
        let single_flips: [FlipVector]
        let compound_transitions_for_S8_S9_S10: [CompoundVector]
    }

    private struct Root: Decodable {
        let schema: String
        let states_table: [StateVector]
        let exhaustiveness: Exhaustiveness
    }

    private struct KatProblem: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
    }

    private static let states: [String: AssuranceState] = [
        "S0_PEER_LEGACY": .peerLegacy,
        "S1_KC_FAILED": .kcFailed,
        "S2_NFC_AUTHENTICATED": .nfcAuthenticated,
        "S3_NFC_IDENTITY_MISMATCH": .nfcIdentityMismatch,
        "S4_NFC_UNATTESTABLE": .nfcUnattestable,
        "S5_IDENTITY_UNVERIFIED": .identityUnverified,
        "S6_NFC_PRESENT_UNCONFIRMED": .nfcPresentUnconfirmed,
        "S7_EXPECTED_NFC_STRIPPED": .expectedNfcStripped,
        "S8_PSK_CONFIRMED": .pskConfirmed,
        "S9_PSK_UNCONFIRMED": .pskUnconfirmed,
        "S10_PQC_ONLY": .pqcOnly
    ]

    private static let kcStatuses: [String: KeyConfirmation.Status] = [
        "VERIFIED": .verified,
        "ABSENT": .absent,
        "WRONG": .wrong
    ]

    // MARK: - Loading

    private func loadKat(file: StaticString = #filePath, line: UInt = #line) throws -> Root {
        let relativePath = "tools/kat/assurance-state/assurance-state-kat.json"
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(Root.self, from: Data(contentsOf: candidate))
            }
        }
        XCTFail("\(relativePath) not found from \(file): the assurance-state vectors cannot run", file: file, line: line)
        throw KatProblem(what: "KAT file not found: \(relativePath)")
    }

    // MARK: - Running one vector

    private func decide(_ i: Inputs) throws -> AssuranceState {
        let mixRoles: [AssuranceState.MixSecretRole] = try i.mixRoles.map { name in
            guard let role = AssuranceState.MixSecretRole(rawValue: name) else {
                throw KatProblem(what: "unknown mix role \(name)")
            }
            return role
        }
        guard let kcStatus = Self.kcStatuses[i.kcStatus] else {
            throw KatProblem(what: "unknown kcStatus \(i.kcStatus)")
        }
        let nfcConfirmed = i.peerAdvertisedRoles.contains(where: { PskAdvertV3.isPresenceRole($0) })
        return AssuranceState.decide(
            peerSupportsMix: i.peerSupportsMix, n: i.N, mixRoles: mixRoles,
            nfcConfirmed: nfcConfirmed, expectedNfc: i.expectedNfc, kcStatus: kcStatus,
            sigOk: i.sigOk, nfcBound: i.nfcBound, witnessOk: i.witnessOk,
            floorRecorded: i.floorRecorded, mediaDwellMs: i.mediaDwellMs
        )
    }

    private func expectedState(_ name: String) throws -> AssuranceState {
        guard let state = Self.states[name] else { throw KatProblem(what: "unknown expectedState \(name)") }
        return state
    }

    private func check(_ inputs: Inputs, expects name: String, label: String) throws {
        let actual = try decide(inputs)
        let expected = try expectedState(name)
        XCTAssertEqual(actual, expected, "[\(label)] expected \(name)")
    }

    // MARK: - Vectors

    func testSchema() throws {
        let kat = try loadKat()
        XCTAssertEqual(kat.schema, "qaudion-assurance-state-kat:1")
    }

    func testEveryStatesTableVector() throws {
        let kat = try loadKat()
        XCTAssertGreaterThan(kat.states_table.count, 0)
        for v in kat.states_table {
            try check(v.inputs, expects: v.expectedState, label: v.comment)
        }
    }

    func testTheS2BaselineAndEverySingleFlip() throws {
        let exhaustive = try loadKat().exhaustiveness
        try check(exhaustive.s2_baseline, expects: exhaustive.s2_baseline_expected_state, label: "s2_baseline")
        XCTAssertGreaterThan(exhaustive.single_flips.count, 0)
        for (index, v) in exhaustive.single_flips.enumerated() {
            try check(v.resultingInputs, expects: v.expectedState, label: "single_flips[\(index)]")
        }
    }

    func testEveryCompoundTransition() throws {
        let exhaustive = try loadKat().exhaustiveness
        XCTAssertGreaterThan(exhaustive.compound_transitions_for_S8_S9_S10.count, 0)
        for v in exhaustive.compound_transitions_for_S8_S9_S10 {
            try check(v.resultingInputs, expects: v.expectedState, label: v.note)
        }
    }
}
// swiftlint:enable identifier_name
