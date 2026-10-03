import XCTest
@testable import QAudionEngine

/// W-M15ORDER (2026-10-03) — the relay sender must never put a frame on the wire UNSEALED once the
/// call negotiated the M-15 relay seal. The send sealer is installed a few milliseconds after the
/// engine gets its session key, so the first mic frame (and an early hang-up / NACK control frame)
/// could go out before it, and the peer's receive sealer (already installed) took that frame's
/// random "counter" into its replay window.
final class RelaySealTxPolicyTests: XCTestCase {

    private static let key = Data((1...32).map { UInt8($0) })

    private func senderAndPeerReceiver() throws -> (send: PqcRtpFrameSealer, peerRecv: PqcRtpFrameSealer) {
        let a = try PqcRtpFrameSealer.createDirectional(
            pqcSessionKey: Self.key, callId: "call-tx-policy", selfIsRoleA: true)
        let b = try PqcRtpFrameSealer.createDirectional(
            pqcSessionKey: Self.key, callId: "call-tx-policy", selfIsRoleA: false)
        return (a.send, b.recv)
    }

    func testDecisionTable() {
        XCTAssertEqual(RelaySealTxPolicy.decide(m15Negotiated: true, sealerInstalled: true), .seal)
        XCTAssertEqual(RelaySealTxPolicy.decide(m15Negotiated: true, sealerInstalled: false), .hold)
        XCTAssertEqual(RelaySealTxPolicy.decide(m15Negotiated: false, sealerInstalled: false), .sendPlain)
        // A sealer that exists is always used, whatever the negotiation flag says.
        XCTAssertEqual(RelaySealTxPolicy.decide(m15Negotiated: false, sealerInstalled: true), .seal)
    }

    func testNeverEmitsAnUnsealedFrameWhenM15IsNegotiatedAndTheSealerIsMissing() {
        let frame = Data(repeating: 0x42, count: 295)
        XCTAssertNil(RelaySealTxPolicy.frameForWire(frame, m15Negotiated: true, sealer: nil),
                     "the frame must be held, not sent plain")
    }

    func testSealsWhenTheSealerExistsAndThePeerCanOpenIt() throws {
        let (send, peerRecv) = try senderAndPeerReceiver()
        let frame = Data("audio envelope".utf8)
        let wire = try XCTUnwrap(RelaySealTxPolicy.frameForWire(frame, m15Negotiated: true, sealer: send))
        XCTAssertNotEqual(wire, frame)
        XCTAssertEqual(try peerRecv.open(wire), frame)
    }

    func testPassesThroughWhenM15WasNotNegotiated() {
        let frame = Data("legacy peer frame".utf8)
        XCTAssertEqual(RelaySealTxPolicy.frameForWire(frame, m15Negotiated: false, sealer: nil), frame)
    }

    /// The two orderings of the real race, replayed against the policy and a real receiver:
    /// mic ticks before the install must be HELD, mic ticks after it go out sealed, and the peer
    /// (whose receive sealer exists the whole time) decodes every frame that did go out.
    func testEveryFrameThatLeavesIsSealedInBothOrderings() throws {
        enum Step { case tick, install }
        // Caller: the engine key is set, ticks race the install. Responder: the install precedes
        // the first tick. Both orderings, plus a pathological late install.
        let orderings: [[Step]] = [
            [.tick, .tick, .install, .tick, .tick],   // caller, race lost by the install
            [.install, .tick, .tick, .tick],          // responder / synchronous install
            [.tick, .tick, .tick, .tick, .install],   // install very late (main-thread hang)
        ]
        for steps in orderings {
            let (send, peerRecv) = try senderAndPeerReceiver()
            var installed: PqcRtpFrameSealer?
            var emitted = 0
            var held = 0
            for (i, step) in steps.enumerated() {
                switch step {
                case .install:
                    installed = send
                case .tick:
                    let frame = Data("mic frame \(i)".utf8)
                    if let wire = RelaySealTxPolicy.frameForWire(frame, m15Negotiated: true, sealer: installed) {
                        emitted += 1
                        XCTAssertEqual(try peerRecv.open(wire), frame,
                                       "a frame that left must be sealed and decode on the peer")
                    } else {
                        held += 1
                    }
                }
            }
            func isTick(_ s: Step) -> Bool {
                if case .tick = s { return true }
                return false
            }
            let ticksBeforeInstall: Int = steps.prefix(while: isTick).count
            XCTAssertEqual(held, ticksBeforeInstall)
            XCTAssertEqual(emitted + held, steps.filter(isTick).count)
        }
    }
}
