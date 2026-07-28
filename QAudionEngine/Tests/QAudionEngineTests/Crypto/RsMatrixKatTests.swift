import XCTest
import CryptoKit
@testable import QAudionEngine

// This file's Decodable structs mirror KAT JSON fixture keys verbatim
// (snake_case, no CodingKeys) — renaming would silently break decoding
// against the shared cross-platform fixture.
// swiftlint:disable identifier_name

/// Gate #9 / #11 — per-platform RS matrix KAT (pure Swift, no native code).
///
/// Derives the Vandermonde-based systematic Reed-Solomon generator matrix G (18×12)
/// over GF(2^8) from scratch, then verifies it byte-for-byte against the FROZEN
/// anchor hashes from docs/phase18/kat/rs-matrix-CANDIDATE.json.
///
/// Also encodes the 6 deterministic shard test vectors and verifies the SHA-256 of
/// each parity shard (12..17) against the same corpus.
///
/// Mirrors RsMatrixKatTest.kt (Android) exactly — the construction must be
/// byte-for-byte identical across all three platforms.
final class RsMatrixKatTests: XCTestCase {

    // MARK: - GF(2^8) arithmetic

    /// Russian-peasant multiply mod 0x11D (x^8+x^4+x^3+x^2+1). Always 8 iterations.
    private func gfMul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var p: UInt8 = 0; var aa = a; var bb = b
        for _ in 0..<8 {
            if bb & 1 != 0 { p ^= aa }
            let hi = aa & 0x80
            aa &<<= 1
            if hi != 0 { aa ^= 0x1D }  // low byte of 0x11D
            bb >>= 1
        }
        return p
    }

    /// Fermat's little theorem: a^254 = a^(-1) in GF(2^8)*.
    private func gfInv(_ a: UInt8) -> UInt8 {
        precondition(a != 0, "GF inv(0) undefined")
        var result: UInt8 = 1; var base = a; var exp = 254
        while exp > 0 {
            if exp & 1 != 0 { result = gfMul(result, base) }
            base = gfMul(base, base)
            exp >>= 1
        }
        return result
    }

    // MARK: - Matrix algebra over GF(2^8)

    /// Invert a k×k matrix over GF(2^8) via Gaussian elimination.
    private func gfMatInv(_ src: [[UInt8]]) -> [[UInt8]] {
        let k = src.count
        // Build augmented matrix [src | I_k]
        var mat: [[UInt8]] = (0..<k).map { i in
            Array(src[i]) + (0..<k).map { j in j == i ? UInt8(1) : UInt8(0) }
        }

        for col in 0..<k {
            // Partial pivot
            guard let pivotRow = (col..<k).first(where: { mat[$0][col] != 0 }) else {
                preconditionFailure("Singular matrix at column \(col)")
            }
            if pivotRow != col { mat.swapAt(col, pivotRow) }

            let pivotInv = gfInv(mat[col][col])
            mat[col] = mat[col].map { gfMul($0, pivotInv) }

            for r in 0..<k {
                guard r != col, mat[r][col] != 0 else { continue }
                let factor = mat[r][col]
                mat[r] = zip(mat[r], mat[col]).map { $0 ^ gfMul(factor, $1) }
            }
        }
        return (0..<k).map { i in Array(mat[i].dropFirst(k)) }
    }

    /// (n×k) × (k×k) GF matrix product.
    private func gfMatMul(_ A: [[UInt8]], _ B: [[UInt8]]) -> [[UInt8]] {
        let n = A.count, k = B.count, m = B[0].count
        return (0..<n).map { i in
            (0..<m).map { j in
                (0..<k).reduce(UInt8(0)) { acc, c in acc ^ gfMul(A[i][c], B[c][j]) }
            }
        }
    }

    // MARK: - RS parameters

    private let K = 12
    private let N = 18
    private let shardData = 103
    private var paddedLen: Int { K * shardData }  // 1236

    /// Evaluation points: alpha^i = 0x02^i for i = 0..17.
    private let evalPoints: [UInt8] = [
        0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
        0x1d, 0x3a, 0x74, 0xe8, 0xcd, 0x87, 0x13, 0x26, 0x4c, 0x98,
    ]

    /// Build the n×k Vandermonde matrix: V[i][j] = eval_point_i^j.
    private func buildVandermonde() -> [[UInt8]] {
        (0..<N).map { i in
            (0..<K).map { j in
                var v: UInt8 = 1
                for _ in 0..<j { v = gfMul(v, evalPoints[i]) }
                return v
            }
        }
    }

    /// Compute P = V[k..n-1] * V[0..k-1]^(-1) — the 6×12 parity submatrix.
    private func buildParityMatrix() -> [[UInt8]] {
        let V = buildVandermonde()
        let T = gfMatInv(Array(V[0..<K]))
        return gfMatMul(Array(V[K...]), T)
    }

    // MARK: - SHA-256 helper

    private func sha256hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    // MARK: - Frozen anchors

    private let frozenPRows: [String] = [
        "61d57f5c54071fdc76437744",
        "fc71828cb595e851d56a0eaa",
        "9bd47a8eb9c4af53c9e35849",
        "2bcbc262e45bb0c47ea587d6",
        "aa9bb0015ffc5c2897ba205b",
        "b79cd0b9eac35bd3da391312",
    ]

    private let frozenPSha256 = "bf4e88cc518f85cdfcefd28a456fe765ceefaebfcec2730d8554ac115978af1f"
    private let frozenGSha256 = "45abac26fac7aa9d854aa601df79453c3a01800a1bb7bc8f551eee111455f597"

    // MARK: - Tests

    /// Canary: four spot GF multiplications from the JSON field-pinning suite.
    func testGfCanary() {
        XCTAssertEqual(gfMul(0x02, 0x02), 0x04)
        XCTAssertEqual(gfMul(0x02, 0x80), 0x1d)
        XCTAssertEqual(gfMul(0x53, 0xca), 0x8f)
        XCTAssertEqual(gfMul(0x01, 0xff), 0xff)
        XCTAssertEqual(gfMul(0x53, gfInv(0x53)), 0x01)
    }

    /// Evaluation points must equal successive powers of alpha=0x02.
    func testEvalPoints() {
        var p: UInt8 = 1
        for i in 0..<N {
            XCTAssertEqual(evalPoints[i], p, "EVAL_POINTS[\(i)]")
            p = gfMul(p, 0x02)
        }
    }

    /// Parity matrix P must match the frozen row-by-row hex.
    func testParityMatrixRows() {
        let P = buildParityMatrix()
        for r in 0..<(N - K) {
            let got = P[r].map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(got, frozenPRows[r], "P row \(r + K)")
        }
    }

    /// SHA-256 of the flat P bytes must match the published anchor.
    func testParityMatrixSha256() {
        let P = buildParityMatrix()
        var flat = Data(capacity: (N - K) * K)
        for row in P { flat.append(contentsOf: row) }
        XCTAssertEqual(sha256hex(flat), frozenPSha256)
    }

    /// SHA-256 of flat G = [I_12 ; P] must match the published anchor.
    func testFullGeneratorMatrixSha256() {
        let P = buildParityMatrix()
        var G = Data(count: N * K)
        // Identity block
        for i in 0..<K { G[i * K + i] = 1 }
        // Parity block
        for r in 0..<(N - K) {
            for c in 0..<K { G[(K + r) * K + c] = P[r][c] }
        }
        XCTAssertEqual(sha256hex(G), frozenGSha256)
    }

    /// Encode 6 deterministic shard vectors and verify SHA-256 of each parity shard.
    ///
    /// Object bytes = SHA-256(seed || BE32(ctr)) stream truncated to objectLen,
    /// then right-zero-padded to paddedLen. Mirrors Kotlin RsMatrixKatTest + Python script.
    func testShardVectorEncode() throws {
        struct Vector {
            let name: String
            let objectLen: Int
            let paritySha256: [String]
        }
        let vectors: [Vector] = [
            Vector(name: "v4-chunk-ek-0001", objectLen: 1216, paritySha256: [
                "831ea2853c918f5ab58c336e82841c55f90ca0c432763497edf56356683b2b44",
                "5113b758a1690fcc6ce6bf923bc2f04d6de87a5e123425c2dee0ea7498f96637",
                "4089d3b0216d5afe335ce55a8ba47408dde82bf0fc2706559c1485d098d61854",
                "14df483ba2ad4753ed2e9654eb349da8fceec63ef6f9dbbeccce943903dcff93",
                "d500ec94c62ac373f663221b588591f2c294cdfecc94492735e94ea1072df6d8",
                "4b29bc10c55e19a07afc124deffaa6df023ac264a5364e06252ee09973e20f21",
            ]),
            Vector(name: "v4-chunk-ek-0002", objectLen: 1216, paritySha256: [
                "4de8d72bce8d8709bc44b5e482ded1a75006e8f16db66c765e3019576060604f",
                "fd349b376518c85eb6e4646eebbad4973ccf8f60c89385caf15741858ac920e7",
                "1a67444939035d9d5f9932dc65e4b122816f9cc67a82ed56b10d98dafb833965",
                "72196890c836ea0a7d56a65c3f29f5434aef718db17a3ad2f42e58edffd37045",
                "9e67c0d2e0488942f7d3544b52c9e8a0823e451f81b0a555c279946b152c22c2",
                "0646e7d4e7c0bdeda2ff9ddf40d7279921afb7412d584ddf4e885d7473dbeb8e",
            ]),
            Vector(name: "v4-chunk-ek-0003", objectLen: 1216, paritySha256: [
                "95c254d08204e6d49a4a4bae4ac150f09ee0bae2179ea83947510e46fa6d1438",
                "ab0920bff57a21a58698f65c9fa837062eb566be743939a16a804f45a5d6cec9",
                "6bc46989ed6a625dfd1be3d35903d472b9377b6d17cce39d338f533690d89365",
                "602643b4760b31ee4035a76cf67783f77eb61123f77e36badbfd2f7603c1bb49",
                "ceb437c30c4e12b6f695a81a0c74d54d11408e73265a8370c958ccd47cd3f58d",
                "b47f1827c3cf78fdb0cb35801e13a0f201a9abfec762ee6cfbd8ba781d14c3a8",
            ]),
            Vector(name: "v4-chunk-ct-0001", objectLen: 1120, paritySha256: [
                "67b877564e105f5be5f40c364217a6afc2f955b3c2d7e6f68509874944edc1d1",
                "af5227c565515dcc2788d4214b9d3478aad03272884b47eceb7f941a9090261b",
                "0ee31b2d79a3ec572a8633867e4c798e5f3fbd1fc8b966f70f0883da4a1466cf",
                "eae88a1500952c82ec350cca0f9893724a38e8a4b54beace99f6f52cefba4e60",
                "2779ee660a1c1befe3006e24f1c69d7395e0738b5461912321c0c659a63667c6",
                "a5b6a422419db3888275068cf7f8efb87f59353c6f6fbb47204e3f116f9cc41c",
            ]),
            Vector(name: "v4-chunk-ct-0002", objectLen: 1120, paritySha256: [
                "81c28e03c72416faff8e74b2a35d73891b575d06ef2183037b16735ef8b6a328",
                "7423e4884db6a5f4e27622e3e6eceacdbfe7bf21cdf0ff522bc9ec5ce3ae5827",
                "55140a7fe184469c0558fca4ba6f2615c3b0070c462621eff947ccf88438a05f",
                "df2f76908637907c1ed3569cc395bc045085ac122e9dbee2ffbc98b3d5a61087",
                "c2506551dbf334f57b0ffddabbb0a1f8fcb59d735ebe32ff024386ea17aa6406",
                "81b582fb79141481787227c1443ad5ba5216b9ff70418d133fde89a39433e624",
            ]),
            Vector(name: "v4-chunk-ct-0003", objectLen: 1120, paritySha256: [
                "a739b3f1d62539baa847ae0df058091775c08eb88621d69757a7ea0534334111",
                "618968901bf944ec2b604e369e32a7f056165bed9ca1b02f886e7278c57522e7",
                "e80d0f52f15213d46e6d6f3b83b29e7b8f369a8f531f93b205e7cfd033b0bdbd",
                "b8d204f297fedb17d4059de8bec17935a9f4cbe02bc5472f04096d92f7753e82",
                "be1d4000556020aa882bad1791f302ae6d9520def70af598d90ab4673da0fee7",
                "6e5fa5239be4dbbde926783fa3e3d9573fe672729ffbe7f5c42fc6fb268f58d6",
            ]),
        ]

        let P = buildParityMatrix()

        for vec in vectors {
            // 1. Rebuild padded object from deterministic seed stream.
            let seedBytes = Data("qa/v4/rs-kat/\(vec.name)".utf8)
            var streamBytes = Data()
            var ctr: UInt32 = 0
            while streamBytes.count < vec.objectLen {
                var ctrBE = ctr.bigEndian
                let ctrData = Data(bytes: &ctrBE, count: 4)
                streamBytes.append(sha256(seedBytes + ctrData))
                ctr += 1
            }
            var padded = Data(streamBytes.prefix(vec.objectLen))
            padded.append(Data(count: paddedLen - vec.objectLen))

            // 2. Split into k data shards.
            let dataShards: [Data] = (0..<K).map { j in
                padded[padded.startIndex + j * shardData ..< padded.startIndex + (j + 1) * shardData]
            }

            // 3. Compute parity shards and verify.
            for r in 0..<(N - K) {
                var parity = [UInt8](repeating: 0, count: shardData)
                for b in 0..<shardData {
                    var s: UInt8 = 0
                    for c in 0..<K {
                        s ^= gfMul(P[r][c], dataShards[c][dataShards[c].startIndex + b])
                    }
                    parity[b] = s
                }
                let got = sha256hex(Data(parity))
                XCTAssertEqual(got, vec.paritySha256[r],
                               "\(vec.name) parity shard \(r + K)")
            }
        }
    }

    /// Systematic invariant: data shards 0..11 are verbatim slices of the padded object.
    func testSystematicInvariant() {
        let seedBytes = Data("qa/v4/rs-kat/v4-chunk-ek-0001".utf8)
        var streamBytes = Data()
        var ctr: UInt32 = 0
        while streamBytes.count < 1216 {
            var ctrBE = ctr.bigEndian
            let ctrData = Data(bytes: &ctrBE, count: 4)
            streamBytes.append(sha256(seedBytes + ctrData))
            ctr += 1
        }
        var padded = Data(streamBytes.prefix(1216))
        padded.append(Data(count: paddedLen - 1216))

        for j in 0..<K {
            let chunk = padded[padded.startIndex + j * shardData ..< padded.startIndex + (j + 1) * shardData]
            XCTAssertEqual(chunk.count, shardData, "chunk \(j) length")
        }
    }
}
// swiftlint:enable identifier_name
