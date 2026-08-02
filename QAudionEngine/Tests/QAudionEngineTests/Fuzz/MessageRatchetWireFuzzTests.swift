import XCTest
@testable import QAudionEngine

/// Fuzz / property tests for the v3 wire decode path
/// (`MessageRatchet.isV3Wire` + the `decrypt`→`unpackWire` pipeline).
///
/// Property under test: feeding ANY byte sequence — empty, 1 byte,
/// boundary-length, all-0x00, all-0xFF, random, mutated, or a
/// non-zero-`startIndex` slice — must result in a clean `nil`
/// (`decrypt`) or a thrown `RatchetError` (`decryptOrThrow`). It must
/// never trap, OOB-read, or hang. A Swift runtime trap aborts the
/// XCTest process, which IS the failure — no extra assertion needed.
final class MessageRatchetWireFuzzTests: XCTestCase {

    private let psk = Data(repeating: 0x42, count: 32)
    private let epoch = "epoch-fuzz"

    private func makeSession() throws -> (MessageRatchet, RatchetSession) {
        let ratchet = MessageRatchet(vault: InMemoryRatchetVault())
        let sess = try ratchet.ensureSession(
            epochId: epoch, selfId: "alice", peerId: "bob", pskRoot: psk)
        return (ratchet, sess)
    }

    /// `isV3Wire` is a pure 1-byte probe — must tolerate everything.
    func testIsV3WireNeverCrashes() {
        for d in FuzzCorpus.fillCorpus(maxLen: 600) {
            _ = MessageRatchet.isV3Wire(d)
            _ = MessageRatchet.isV3Wire(FuzzCorpus.sliced(d))
        }
        for d in FuzzCorpus.randomCorpus(maxLen: 600, perLength: 4, seed: 0xA11CE) {
            _ = MessageRatchet.isV3Wire(d)
            _ = MessageRatchet.isV3Wire(FuzzCorpus.sliced(d))
        }
        _ = MessageRatchet.isV3Wire(Data())
    }

    /// Random + fill corpus through the public `decrypt`. Any input
    /// must yield `nil`, never a crash.
    func testDecryptRandomCorpusFailsSoft() throws {
        let (ratchet, sess) = try makeSession()
        let aad = Data("ad".utf8)
        for d in FuzzCorpus.fillCorpus(maxLen: 600) {
            XCTAssertNil(ratchet.decrypt(session: sess, wire: d, aad: aad))
        }
        for d in FuzzCorpus.randomCorpus(maxLen: 600, perLength: 6, seed: 0xDEAD_BEEF) {
            XCTAssertNil(ratchet.decrypt(session: sess, wire: d, aad: aad))
        }
    }

    /// Same corpus but through `decryptOrThrow` — must throw a
    /// `RatchetError`, never trap.
    func testDecryptOrThrowAlwaysThrowsCleanly() throws {
        let (ratchet, sess) = try makeSession()
        let aad = Data()
        for d in FuzzCorpus.randomCorpus(maxLen: 600, perLength: 4, seed: 7) {
            do {
                _ = try ratchet.decryptOrThrow(session: sess, wire: d, aad: aad)
                // A random buffer that decrypts is astronomically
                // improbable; if it ever does, that's still "no crash".
            } catch is MessageRatchet.RatchetError {
                // expected fail-soft path
            } catch {
                // Any other error type is still "no crash" — acceptable.
            }
        }
    }

    /// Hand-built near-valid v3 headers: correct magic 0xE3 then
    /// adversarial `epoch_len` (0, 1, 255), short bodies, and the
    /// MAXLEN±1 epoch lengths. Exercises the bound math in
    /// `unpackWire` directly through the public surface.
    func testCraftedV3HeadersFailSoft() throws {
        let (ratchet, sess) = try makeSession()
        let aad = Data()
        let magic: UInt8 = 0xE3

        var crafted: [Data] = []
        crafted.append(Data([magic]))                       // magic only
        crafted.append(Data([magic, 0x00]))                 // epoch_len=0
        crafted.append(Data([magic, 0x01]))                 // epoch_len=1, nothing follows
        crafted.append(Data([magic, 0xFF]))                 // epoch_len=255, nothing follows
        for epochLen in [1, 2, 32, 64, 254, 255] {
            // header claims epochLen but body is one byte short of the
            // minimum (epoch + dir + 8-byte idx + 16-byte tag).
            var d = Data([magic, UInt8(epochLen)])
            d.append(Data(repeating: 0x61, count: epochLen)) // ascii 'a' epoch
            d.append(0x01)                                   // dir flag
            d.append(Data(repeating: 0, count: 8))           // chain idx
            d.append(Data(repeating: 0, count: 15))          // tag minus 1 byte
            crafted.append(d)
            // and with a non-UTF8 epoch region
            var bad = Data([magic, UInt8(epochLen)])
            bad.append(Data(repeating: 0xFF, count: epochLen))
            bad.append(0x01)
            bad.append(Data(repeating: 0, count: 8 + 16))
            crafted.append(bad)
        }
        for d in crafted {
            XCTAssertNil(ratchet.decrypt(session: sess, wire: d, aad: aad))
            XCTAssertNil(ratchet.decrypt(session: sess,
                                         wire: FuzzCorpus.sliced(d), aad: aad))
        }
    }

    /// Mutations of a real ciphertext frame produced by `encrypt`.
    /// Every flip/truncate/extend must still fail-soft on decode.
    func testMutatedRealFrameFailsSoft() throws {
        let (ratchet, sendSess) = try makeSession()
        // Build a genuine wire frame, then decode-fuzz its corruptions
        // against a fresh receiver session.
        let aad = MessageRatchet.buildMessageAD(
            senderId: "alice", recipientId: "bob", clientMsgId: "m1")
        let wire = try ratchet.encrypt(
            session: sendSess, plaintext: Data("hello".utf8),
            aad: aad, clientMsgId: "m1")

        let rxRatchet = MessageRatchet(vault: InMemoryRatchetVault())
        let rxSess = try rxRatchet.ensureSession(
            epochId: epoch, selfId: "bob", peerId: "alice", pskRoot: psk)

        // `mutations(of:)` does NOT guarantee its output differs from the
        // input: the "random splice" case assigns `m[i] = rng.byte()`, which
        // reproduces the byte already there 1 time in 256, and the
        // zero-a-region / 0xFF-a-region cases are no-ops over a region that
        // already holds those bytes. Across 4000 draws an identity copy is
        // expected a couple of times, and an UNMODIFIED frame decrypting
        // correctly is the ratchet behaving exactly as it must — it is not a
        // fuzz finding. That is the whole reason this case failed
        // (`XCTAssertNil failed: "5 bytes"`, the length of the "hello"
        // plaintext) and, on 2026-06-19, got switched off in CI instead of
        // read: the AEAD cannot produce a valid 5-byte plaintext from a
        // genuinely altered ciphertext, so the one output that reached the
        // assertion had to be the original frame.
        //
        // Filtering the identity keeps the real property — every ACTUAL
        // mutation must fail soft — and drops only the case that was never
        // a mutation. Nothing here is weakened: the flip/truncate/extend
        // corpus still runs in full.
        for m in FuzzCorpus.mutations(of: wire, count: 4000, rngSeed: 0xF00D) where m != wire {
            XCTAssertNil(rxRatchet.decrypt(session: rxSess, wire: m, aad: aad))
        }
        // Also feed the un-mutated frame through a slice view — a
        // non-crashing return (any value) is the property under test.
        let slicedResult = rxRatchet.decrypt(
            session: rxSess, wire: FuzzCorpus.sliced(wire), aad: aad)
        _ = slicedResult
    }
}
