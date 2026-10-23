import XCTest
@testable import QAudionEngine

/// The adaptive sampling tiers of a live share (docs/LOCATION_SHARING.md 1.1). Pure logic: a fix at a time, the tier in force.
final class LocationSamplingPolicyTests: XCTestCase {

    /// About 0.000009 degrees of latitude is one metre.
    private func metresNorth(_ metres: Double) -> Double { 45.0 + metres * 0.000_009_01 }

    func testTheTiersMapOntoTheSystemSettings() {
        XCTAssertEqual(LocationSamplingTier.moving.desiredAccuracyMetres, 10)
        XCTAssertEqual(LocationSamplingTier.moving.distanceFilterMetres, 10)
        XCTAssertEqual(LocationSamplingTier.still.desiredAccuracyMetres, 100)
        XCTAssertEqual(LocationSamplingTier.still.distanceFilterMetres, 50)
    }

    func testAShareStartsMoving() {
        var policy = LocationSamplingPolicy()
        XCTAssertEqual(policy.tier, .moving)
        XCTAssertEqual(policy.ingest(latitude: 45, longitude: 9, speed: nil, at: 0), .moving)
    }

    func testThreeQuietMinutesLeadToTheStillTier() {
        var policy = LocationSamplingPolicy()
        policy.ingest(latitude: 45, longitude: 9, speed: 0, at: 0)
        // A few metres of jitter is not a displacement of 25 m.
        XCTAssertEqual(policy.ingest(latitude: metresNorth(5), longitude: 9, speed: 0, at: 60), .moving)
        XCTAssertEqual(policy.ingest(latitude: metresNorth(8), longitude: 9, speed: 0, at: 179), .moving)
        XCTAssertEqual(policy.ingest(latitude: metresNorth(3), longitude: 9, speed: 0, at: 180), .still)
    }

    func testADisplacementOf25MetresRestartsTheQuietPeriod() {
        var policy = LocationSamplingPolicy()
        policy.ingest(latitude: 45, longitude: 9, speed: 0, at: 0)
        XCTAssertEqual(policy.ingest(latitude: metresNorth(30), longitude: 9, speed: 0, at: 150), .moving)
        // The 180 s count starts again from the new anchor.
        XCTAssertEqual(policy.ingest(latitude: metresNorth(31), longitude: 9, speed: 0, at: 300), .moving)
        XCTAssertEqual(policy.ingest(latitude: metresNorth(31), longitude: 9, speed: 0, at: 330), .still)
    }

    func testTimePassingWithoutAFixAlsoReachesTheStillTier() {
        var policy = LocationSamplingPolicy()
        policy.ingest(latitude: 45, longitude: 9, speed: 0, at: 0)
        XCTAssertEqual(policy.idle(at: 100), .moving)
        XCTAssertEqual(policy.idle(at: 181), .still)
    }

    func testFiftyMetresFromTheStillAnchorLeavesTheStillTier() {
        var policy = LocationSamplingPolicy()
        policy.ingest(latitude: 45, longitude: 9, speed: 0, at: 0)
        XCTAssertEqual(policy.idle(at: 200), .still)
        XCTAssertEqual(policy.ingest(latitude: metresNorth(40), longitude: 9, speed: nil, at: 210), .still)
        XCTAssertEqual(policy.ingest(latitude: metresNorth(60), longitude: 9, speed: nil, at: 220), .moving)
    }

    func testASpeedOfOneMetrePerSecondLeavesTheStillTier() {
        var policy = LocationSamplingPolicy()
        policy.ingest(latitude: 45, longitude: 9, speed: 0, at: 0)
        XCTAssertEqual(policy.idle(at: 200), .still)
        XCTAssertEqual(policy.ingest(latitude: 45, longitude: 9, speed: 0.9, at: 210), .still)
        XCTAssertEqual(policy.ingest(latitude: 45, longitude: 9, speed: 1.0, at: 220), .moving)
    }

    func testResetForgetsTheAnchor() {
        var policy = LocationSamplingPolicy()
        policy.ingest(latitude: 45, longitude: 9, speed: 0, at: 0)
        XCTAssertEqual(policy.idle(at: 200), .still)
        policy.reset()
        XCTAssertEqual(policy.tier, .moving)
        // Nothing of the earlier position is kept: a fix far away is simply the first one.
        XCTAssertEqual(policy.ingest(latitude: 10, longitude: 10, speed: nil, at: 1_000), .moving)
    }

    func testThePolicyDescribesItselfWithoutAPosition() {
        var policy = LocationSamplingPolicy()
        policy.ingest(latitude: 45.4642110, longitude: 9.1899820, speed: nil, at: 0)
        XCTAssertEqual("\(policy)", "LocationSamplingPolicy(redacted)")
    }

    func testTheDistanceIsGreatCircle() {
        // One degree of latitude is about 111.2 km.
        let metres = LocationSamplingPolicy.distanceMetres(45, 9, 46, 9)
        XCTAssertEqual(metres, 111_195, accuracy: 100)
        XCTAssertEqual(LocationSamplingPolicy.distanceMetres(45, 9, 45, 9), 0, accuracy: 0.001)
    }
}
