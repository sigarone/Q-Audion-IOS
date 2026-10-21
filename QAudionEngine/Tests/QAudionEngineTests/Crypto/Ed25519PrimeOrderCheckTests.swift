import XCTest
import CryptoKit
@testable import QAudionEngine

/// `Ed25519PrimeOrderCheck` (docs/security/NFC_PAIRING_V2.md section 3): the identity key of a peer must be a
/// canonical encoding of a point of the prime-order subgroup. The vectors below were produced by the independent
/// Python reference (`ed_identity_key_ok` of scripts/kat/gen_nfc_pairing_kat.py): honest keys, honest keys plus a
/// torsion point (mixed order, canonical, not in the small-order table), and random 32-byte strings.
final class Ed25519PrimeOrderCheckTests: XCTestCase {

    /// (key, in the prime-order subgroup). The first entries of each group of nine are an honest key, the same key
    /// plus each of the 8 torsion points (plus the neutral element gives the key itself).
    private let vectors: [(String, Bool)] = [
        ("0c51c67faa93d3fd677edc222df5d8346af23f780df3cb3a5f8dca3537b8cddd", true),
        ("0c51c67faa93d3fd677edc222df5d8346af23f780df3cb3a5f8dca3537b8cddd", true),
        ("e1ae3980556c2c02988123ddd20a27cb950dc087f20c34c5a07235cac8473222", false),
        ("baed3e2010691252074ea850b2e2d65f154b87b1999df047c12f3714d7088bf8", false),
        ("3312c1dfef96edadf8b157af4d1d29a0eab4784e66620fb83ed0c8eb28f77407", false),
        ("595c0681f3c4890beba22095190ef3c6cbf1c14cc8ee3ba4c8a40b137f1b21fd", false),
        ("6a9592e4f9a5fbf46eaa20a9ddb4d1b23a09ca74f59dd5021272a97f9a0084d5", false),
        ("e9c43a77ce5579b1feb59f5fdbe097d1c6fbf4a71fabe3d70357c09bbd6206e7", true),
        ("e9c43a77ce5579b1feb59f5fdbe097d1c6fbf4a71fabe3d70357c09bbd6206e7", true),
        ("043bc58831aa864e014a60a0241f682e39040b58e0541c28fca83f64429df918", false),
        ("b0b8a43f686d616f6b9a3485020ecb0eb7bf1e0eb34a3a45f285c2856403e5cf", false),
        ("3d475bc097929e909465cb7afdf134f14840e1f14cb5c5ba0d7a3d7a9bfc1a30", false),
        ("f0351c44695c2a51a04fc5d0ae946594c0f1e99f1a31e85de200705da709c4e8", false),
        ("1476cd2e836c70fde895393238a67758e0754eb5b812fdd93150dfa56c2f2495", false),
        ("0cf1e3acaf2411f3e64e4a973e38c64fd430609258d7c0984812335e3682bac7", true),
        ("0cf1e3acaf2411f3e64e4a973e38c64fd430609258d7c0984812335e3682bac7", true),
        ("e10e1c5350dbee0c19b1b568c1c739b02bcf9f6da7283f67b7edcca1c97d4538", false),
        ("d26d1a5729bf0bbe47c7f6f4b55495af4e4630b463ac9239f640e2075d189c5d", false),
        ("1b92e5a8d640f441b838090b4aab6a50b1b9cf4b9c536dc609bf1df8a2e763a2", false),
        ("ce04ba442c32842cf835c09861d258a94b38378aeb2efdc874ea0f539cba2cd3", false),
        ("6bb28c4ab98f6e5d643dc642991ce6223f8087e66636d5e12baf981cb5922939", false),
        ("464f848264c0025e0db345139ed665d550a3d0ed3274c7d87231721aeffef665", true),
        ("464f848264c0025e0db345139ed665d550a3d0ed3274c7d87231721aeffef665", true),
        ("a7b07b7d9b3ffda1f24cbaec61299a2aaf5c2f12cd8b38278dce8de51001099a", false),
        ("07f393a72097c62abf00f0491078c2097988f07e176da03f3d9fd9ef4368bcaa", false),
        ("e60c6c58df6839d540ff0fb6ef873df686770f81e8925fc0c2602610bc974355", false),
        ("4f4c9d5446767e5e9d3044c3c3495cac73433ebd595591ee67a8ef604f3290c1", false),
        ("89068332a47e4564841dbdc01ba8f1289d8b4f3f79bf6268f75792108ca548a6", true),
        ("6c26af183f9bca6b21139c7f7ce309fd2390b3b509a3dcf8952c6c72564d562c", true),
        ("ad30eb7dbe9bb249e64fe6f4055d9dcf63ad81eafb8983cb93bf442a8a79a6af", true),
        ("15d56ebe2327e933aab8d7f1256fc02844c603bfd2b63aea17d8ad5315c82231", true),
        ("4aa6c8f676381d9ad8edf480868fe07945ddf3d96459a3499453479e4a3de3be", true),
        ("6fb950aa7a59710e4d05e2f276f44498185c79256b2e03ec1ccbb9644e6eea0d", false),
        ("bcd4833604880c06a0e85ff9dcc99b98c8485424c3aa566ae06b450df34ab9b5", false),
        ("3806650f727e212f14bbb06441bc1b73914ceee5a8e847b6948932e2ac686f50", false),
        ("ebc893bb060afb1c1f1d5effc7035114e20a7dee13f9662ae1404954b8a2d030", false),
        ("08ba7d2fa72808a7e8ee95ef43225986e0110ebfcbabb5774d2f2a0858e7d34f", false),
    ]

    private func data(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    func testSubgroupMembershipMatchesTheReference() {
        XCTAssertEqual(vectors.count, 37)
        for (hex, expected) in vectors {
            XCTAssertEqual(Ed25519PrimeOrderCheck.isPrimeOrderSubgroupPoint(data(hex)), expected, hex)
        }
    }

    func testMixedOrderKeyIsNotAcceptableAsIdentityEvenThoughTheTableAndTheEncodingPass() {
        // Second entry of the first group: the honest key plus a torsion point of order 8.
        let honest = data(vectors[0].0)
        let mixed = data(vectors[3].0)
        XCTAssertTrue(Ed25519IdentityKeyPolicy.isAcceptable(mixed), "the table and the encoding checks alone let it through")
        XCTAssertFalse(Ed25519PrimeOrderCheck.isAcceptableIdentityKey(mixed))
        XCTAssertTrue(Ed25519PrimeOrderCheck.isAcceptableIdentityKey(honest))
    }

    func testEveryTableEntryAndTheNonCanonicalEncodingsAreRefused() {
        for point in Ed25519IdentityKeyPolicy.smallOrderPoints {
            XCTAssertFalse(Ed25519PrimeOrderCheck.isAcceptableIdentityKey(point), point.map { String(format: "%02x", $0) }.joined())
        }
        let nonCanonical = [
            "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
            "0100000000000000000000000000000000000000000000000000000000000080",
            "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        ]
        for hex in nonCanonical {
            XCTAssertFalse(Ed25519PrimeOrderCheck.isAcceptableIdentityKey(data(hex)), hex)
        }
    }

    func testWrongLengthsAreRefused() {
        XCTAssertFalse(Ed25519PrimeOrderCheck.isPrimeOrderSubgroupPoint(Data()))
        XCTAssertFalse(Ed25519PrimeOrderCheck.isPrimeOrderSubgroupPoint(Data(count: 31)))
        XCTAssertFalse(Ed25519PrimeOrderCheck.isPrimeOrderSubgroupPoint(Data(count: 33)))
        XCTAssertFalse(Ed25519PrimeOrderCheck.isAcceptableIdentityKey(Data(count: 32)))
    }

    func testKeysFromTheSignerAreAlwaysInTheSubgroup() throws {
        for seed in 1...40 {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: UInt8(seed), count: 32))
            XCTAssertTrue(Ed25519PrimeOrderCheck.isAcceptableIdentityKey(key.publicKey.rawRepresentation), "seed \(seed)")
        }
    }

    func testFieldArithmeticIdentities() {
        typealias Fe = Ed25519PrimeOrderCheck.Fe
        let a = Fe(small: 123_456_789)
        XCTAssertEqual(Fe.mul(a, Fe.inverse(a)), Fe.one)
        XCTAssertEqual(Fe.sub(a, a), Fe.zero)
        XCTAssertEqual(Fe.add(Fe.negate(a), a), Fe.zero)
        // p - 1 squared is 1.
        let minusOne = Fe.negate(Fe.one)
        XCTAssertEqual(Fe.square(minusOne), Fe.one)
        // sqrt(-1)^2 = -1
        XCTAssertEqual(Fe.square(Ed25519PrimeOrderCheck.Curve.sqrtMinusOne), minusOne)
        // The neutral element has order one, the base point order l.
        let identity = Ed25519PrimeOrderCheck.Curve.identity
        let sum = Ed25519PrimeOrderCheck.Curve.add(identity, identity)
        XCTAssertTrue(sum.x.isZero)
        XCTAssertEqual(sum.y, sum.z)
    }
}
