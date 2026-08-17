import XCTest
@testable import QAudionEngine

final class PlanStatusTests: XCTestCase {
    private let now: Int64 = 1_800_000_000 // fixed reference instant, unix seconds

    private func claims(fea: [String: Int64]) -> EgtClaims {
        EgtClaims(
            v: 1, sub: "user-1", did: "device-1", dkt: "dkt", pkg: ["pro"],
            fea: fea, lim: [:], pol: nil, ee: 1, epr: nil, iat: now, exp: now + 3600
        )
    }

    func testNoClaimsIsBase() {
        XCTAssertEqual(derivePlanStatus(claims: nil, nowSeconds: now), .base)
    }

    func testAnchorFeatureAbsentIsBase() {
        XCTAssertEqual(derivePlanStatus(claims: claims(fea: [:]), nowSeconds: now), .base)
    }

    func testAnchorFeatureExpiryZeroIsPerpetual() {
        let c = claims(fea: ["feat.calls.video": 0])
        XCTAssertEqual(derivePlanStatus(claims: c, nowSeconds: now), .proPerpetual)
    }

    func testAnchorFeatureExpiryInFutureRoundsDaysUp() {
        let expiry = now + (10 * 86_400) + 1 // 10 days + 1s out, must round UP to 11
        let c = claims(fea: ["feat.calls.video": expiry])
        guard case let .proTrial(daysRemaining, expiresAt) = derivePlanStatus(claims: c, nowSeconds: now) else {
            return XCTFail("expected .proTrial")
        }
        XCTAssertEqual(daysRemaining, 11)
        XCTAssertEqual(expiresAt, expiry)
    }

    func testAnchorFeatureExpiryOnDayBoundary() {
        let expiry = now + (5 * 86_400) // exactly 5 days out
        let c = claims(fea: ["feat.calls.video": expiry])
        guard case let .proTrial(daysRemaining, _) = derivePlanStatus(claims: c, nowSeconds: now) else {
            return XCTFail("expected .proTrial")
        }
        XCTAssertEqual(daysRemaining, 5)
    }

    func testAnchorFeatureExpiryInPastIsBaseNeverNegativeDayTrial() {
        let c = claims(fea: ["feat.calls.video": now - 3600])
        XCTAssertEqual(derivePlanStatus(claims: c, nowSeconds: now), .base)
    }

    func testAnchorFeatureExpiryExactlyNowIsBase() {
        let c = claims(fea: ["feat.calls.video": now])
        XCTAssertEqual(derivePlanStatus(claims: c, nowSeconds: now), .base)
    }
}
