import XCTest
@testable import QAudionEngine

/// Full truth table of the pure `meshRoutingDecision` (3 preferences x armed x reachable = 12 rows),
/// plus the stored-value parsing. No radio, no UserDefaults, no view model.
final class MeshRoutingPreferenceTests: XCTestCase {

    private func decide(
        _ preference: MeshRoutingPreference,
        armed: Bool,
        reachable: Bool
    ) -> MeshRoutingDecision {
        meshRoutingDecision(
            preference: preference,
            armedMeshTarget: armed,
            peerReachableOverMesh: reachable
        )
    }

    // MARK: - Armed target outranks the stored preference (all three preferences)

    func testArmedAndReachableAlwaysSendsOverMesh() {
        for pref in MeshRoutingPreference.allCases {
            XCTAssertEqual(decide(pref, armed: true, reachable: true), .sendOverMesh, "pref=\(pref)")
        }
    }

    func testArmedAndUnreachableAlwaysQueuesForMesh() {
        for pref in MeshRoutingPreference.allCases {
            XCTAssertEqual(decide(pref, armed: true, reachable: false), .queueForMesh, "pref=\(pref)")
        }
    }

    // MARK: - networkOnly: never the mesh unless explicitly armed

    func testNetworkOnlyNotArmedNeverUsesMesh() {
        XCTAssertEqual(decide(.networkOnly, armed: false, reachable: true), .sendOverNetwork)
        XCTAssertEqual(decide(.networkOnly, armed: false, reachable: false), .sendOverNetwork)
    }

    // MARK: - meshOnly: mesh or wait, never the network

    func testMeshOnlyNotArmedReachableSendsOverMesh() {
        XCTAssertEqual(decide(.meshOnly, armed: false, reachable: true), .sendOverMesh)
    }

    func testMeshOnlyNotArmedUnreachableQueuesInsteadOfFallingBack() {
        XCTAssertEqual(decide(.meshOnly, armed: false, reachable: false), .queueForMesh)
    }

    // MARK: - preferMesh: mesh when reachable, otherwise the network (never strands a message)

    func testPreferMeshNotArmedReachableSendsOverMesh() {
        XCTAssertEqual(decide(.preferMesh, armed: false, reachable: true), .sendOverMesh)
    }

    func testPreferMeshNotArmedUnreachableFallsBackToNetwork() {
        XCTAssertEqual(decide(.preferMesh, armed: false, reachable: false), .sendOverNetwork)
    }

    // MARK: - Invariant: only meshOnly / armed can ever queue

    func testPreferMeshAndNetworkOnlyNeverQueueWhenNotArmed() {
        for pref in [MeshRoutingPreference.preferMesh, .networkOnly] {
            for reachable in [true, false] {
                XCTAssertNotEqual(
                    decide(pref, armed: false, reachable: reachable), .queueForMesh,
                    "pref=\(pref) reachable=\(reachable)"
                )
            }
        }
    }

    // MARK: - Stored value parsing

    func testDefaultIsPreferMesh() {
        XCTAssertEqual(MeshRoutingPreference.default, .preferMesh)
    }

    func testFromStoredRoundTripsEveryCase() {
        for pref in MeshRoutingPreference.allCases {
            XCTAssertEqual(MeshRoutingPreference.fromStored(pref.rawValue), pref)
        }
    }

    func testFromStoredFallsBackToDefaultOnNilOrUnknown() {
        XCTAssertEqual(MeshRoutingPreference.fromStored(nil), .default)
        XCTAssertEqual(MeshRoutingPreference.fromStored(""), .default)
        XCTAssertEqual(MeshRoutingPreference.fromStored("prefer_mesh"), .default, "raw values are case-sensitive")
        XCTAssertEqual(MeshRoutingPreference.fromStored("BOGUS"), .default)
    }

    func testRawValuesMatchAndroid() {
        XCTAssertEqual(MeshRoutingPreference.preferMesh.rawValue, "PREFER_MESH")
        XCTAssertEqual(MeshRoutingPreference.networkOnly.rawValue, "NETWORK_ONLY")
        XCTAssertEqual(MeshRoutingPreference.meshOnly.rawValue, "MESH_ONLY")
    }
}
