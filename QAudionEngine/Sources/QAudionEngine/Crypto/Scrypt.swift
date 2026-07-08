import Foundation
import CommonCrypto

/// RFC 7914 scrypt KDF.
///
/// Implements the full scrypt construction: scrypt(P, S, N, r, p, dkLen)
/// where P=password bytes, S=salt bytes, N=cost factor (must be 2^k > 1),
/// r=block size, p=parallelization, dkLen=output length.
///
/// Reference: https://datatracker.ietf.org/doc/html/rfc7914
///
/// On iOS, CryptoKit doesn't ship scrypt; this is a clean-room implementation
/// using CommonCrypto's PBKDF2-HMAC-SHA256 for the inner derivation step
/// (the KDF wrapping). Salsa20/8, BlockMix, ROMix are implemented in Swift.
public enum Scrypt {

    public enum Error: Swift.Error, LocalizedError {
        case invalidN(Int)
        case invalidR(Int)
        case invalidP(Int)
        case invalidDkLen(Int)
        case pbkdf2Failed

        public var errorDescription: String? {
            switch self {
            case .invalidN(let n): return "N must be 2^k > 1, got \(n)"
            case .invalidR(let r): return "r must be > 0, got \(r)"
            case .invalidP(let p): return "p must be > 0, got \(p)"
            case .invalidDkLen(let n): return "dkLen must be > 0, got \(n)"
            case .pbkdf2Failed: return "PBKDF2 inner step failed"
            }
        }
    }

    /// scrypt(password, salt, N, r, p, dkLen) → derived key bytes.
    public static func deriveKey(
        password: Data,
        salt: Data,
        n: Int,
        r: Int,
        p: Int,
        dkLen: Int
    ) throws -> Data {
        // Validate.
        guard n > 1, (n & (n - 1)) == 0 else { throw Error.invalidN(n) }
        guard r > 0 else { throw Error.invalidR(r) }
        guard p > 0 else { throw Error.invalidP(p) }
        guard dkLen > 0 else { throw Error.invalidDkLen(dkLen) }

        // Step 1: B = PBKDF2-HMAC-SHA256(P, S, 1, p * 128 * r)
        let blockBytes = p * 128 * r
        // ROMix/BlockMix operate on plain [UInt8] via unsafe buffer pointers instead
        // of Data - Data's subscript has real per-access bridging/COW overhead that,
        // multiplied by N (cost factor) iterations of nested byte-level loops, turned
        // a scrypt(N=131072) derivation into minutes instead of ~1s. Algorithm/byte
        // order below is unchanged from the Data-based version (see RFC 7914 KAT
        // tests in ScryptTests.swift), only the storage/access pattern changed.
        let b0 = Array(try pbkdf2(password: password, salt: salt, iterations: 1, dkLen: blockBytes))

        // Step 2: for i in 0..<p, B[i] = ROMix(B[i], N)
        let blockSize = 128 * r
        var blocks = [[UInt8]]()
        blocks.reserveCapacity(p)
        for i in 0..<p {
            let start = i * blockSize
            blocks.append(Array(b0[start..<(start + blockSize)]))
        }
        for i in 0..<p {
            blocks[i] = romix(block: blocks[i], n: n, r: r)
        }
        var b = [UInt8]()
        b.reserveCapacity(blockBytes)
        for blk in blocks { b.append(contentsOf: blk) }

        // Step 3: DK = PBKDF2-HMAC-SHA256(P, B, 1, dkLen)
        return try pbkdf2(password: password, salt: Data(b), iterations: 1, dkLen: dkLen)
    }

    // MARK: - PBKDF2 (CommonCrypto wrapper)

    private static func pbkdf2(password: Data, salt: Data, iterations: Int, dkLen: Int) throws -> Data {
        var derived = Data(count: dkLen)
        let result = derived.withUnsafeMutableBytes { dPtr -> Int32 in
            return password.withUnsafeBytes { pPtr -> Int32 in
                return salt.withUnsafeBytes { sPtr -> Int32 in
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pPtr.bindMemory(to: Int8.self).baseAddress, password.count,
                        sPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        dPtr.bindMemory(to: UInt8.self).baseAddress, dkLen
                    )
                }
            }
        }
        guard result == kCCSuccess else { throw Error.pbkdf2Failed }
        return derived
    }

    // MARK: - Salsa20/8 core (RFC 7914 §3)

    private static func salsa208(_ input: inout [UInt32]) {
        var x = input
        for _ in 0..<4 {
            // 4 double-rounds = 8 rounds total.
            x[ 4] ^= rotl(x[ 0] &+ x[12], 7)
            x[ 8] ^= rotl(x[ 4] &+ x[ 0], 9)
            x[12] ^= rotl(x[ 8] &+ x[ 4], 13)
            x[ 0] ^= rotl(x[12] &+ x[ 8], 18)
            x[ 9] ^= rotl(x[ 5] &+ x[ 1], 7)
            x[13] ^= rotl(x[ 9] &+ x[ 5], 9)
            x[ 1] ^= rotl(x[13] &+ x[ 9], 13)
            x[ 5] ^= rotl(x[ 1] &+ x[13], 18)
            x[14] ^= rotl(x[10] &+ x[ 6], 7)
            x[ 2] ^= rotl(x[14] &+ x[10], 9)
            x[ 6] ^= rotl(x[ 2] &+ x[14], 13)
            x[10] ^= rotl(x[ 6] &+ x[ 2], 18)
            x[ 3] ^= rotl(x[15] &+ x[11], 7)
            x[ 7] ^= rotl(x[ 3] &+ x[15], 9)
            x[11] ^= rotl(x[ 7] &+ x[ 3], 13)
            x[15] ^= rotl(x[11] &+ x[ 7], 18)
            x[ 1] ^= rotl(x[ 0] &+ x[ 3], 7)
            x[ 2] ^= rotl(x[ 1] &+ x[ 0], 9)
            x[ 3] ^= rotl(x[ 2] &+ x[ 1], 13)
            x[ 0] ^= rotl(x[ 3] &+ x[ 2], 18)
            x[ 6] ^= rotl(x[ 5] &+ x[ 4], 7)
            x[ 7] ^= rotl(x[ 6] &+ x[ 5], 9)
            x[ 4] ^= rotl(x[ 7] &+ x[ 6], 13)
            x[ 5] ^= rotl(x[ 4] &+ x[ 7], 18)
            x[11] ^= rotl(x[10] &+ x[ 9], 7)
            x[ 8] ^= rotl(x[11] &+ x[10], 9)
            x[ 9] ^= rotl(x[ 8] &+ x[11], 13)
            x[10] ^= rotl(x[ 9] &+ x[ 8], 18)
            x[12] ^= rotl(x[15] &+ x[14], 7)
            x[13] ^= rotl(x[12] &+ x[15], 9)
            x[14] ^= rotl(x[13] &+ x[12], 13)
            x[15] ^= rotl(x[14] &+ x[13], 18)
        }
        for i in 0..<16 { input[i] = input[i] &+ x[i] }
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        return (x << n) | (x >> (32 - n))
    }

    // MARK: - BlockMix (RFC 7914 §4)

    private static func blockMix(block: [UInt8], r: Int) -> [UInt8] {
        // Treat block as 2r 64-byte chunks. Output: 2r 64-byte chunks rearranged.
        var x = [UInt32](repeating: 0, count: 16)
        // x = B[2r-1] (last 64-byte chunk)
        let lastStart = (2 * r - 1) * 64
        var ys = [[UInt32]](repeating: [UInt32](repeating: 0, count: 16), count: 2 * r)
        block.withUnsafeBufferPointer { blk in
            for i in 0..<16 {
                let off = lastStart + i * 4
                x[i] = UInt32(blk[off]) |
                       (UInt32(blk[off + 1]) << 8) |
                       (UInt32(blk[off + 2]) << 16) |
                       (UInt32(blk[off + 3]) << 24)
            }
            for i in 0..<(2 * r) {
                // x ^= B[i]
                for j in 0..<16 {
                    let off = i * 64 + j * 4
                    let bj = UInt32(blk[off]) |
                             (UInt32(blk[off + 1]) << 8) |
                             (UInt32(blk[off + 2]) << 16) |
                             (UInt32(blk[off + 3]) << 24)
                    x[j] ^= bj
                }
                // x = Salsa(x)
                salsa208(&x)
                ys[i] = x
            }
        }
        // Output: Y[0], Y[2], ..., Y[2r-2], Y[1], Y[3], ..., Y[2r-1]
        var out = [UInt8](repeating: 0, count: 128 * r)
        out.withUnsafeMutableBufferPointer { outBuf in
            var outIdx = 0
            for i in stride(from: 0, to: 2 * r, by: 2) {
                for j in 0..<16 {
                    let v = ys[i][j]
                    outBuf[outIdx] = UInt8(v & 0xFF); outIdx += 1
                    outBuf[outIdx] = UInt8((v >> 8) & 0xFF); outIdx += 1
                    outBuf[outIdx] = UInt8((v >> 16) & 0xFF); outIdx += 1
                    outBuf[outIdx] = UInt8((v >> 24) & 0xFF); outIdx += 1
                }
            }
            for i in stride(from: 1, to: 2 * r, by: 2) {
                for j in 0..<16 {
                    let v = ys[i][j]
                    outBuf[outIdx] = UInt8(v & 0xFF); outIdx += 1
                    outBuf[outIdx] = UInt8((v >> 8) & 0xFF); outIdx += 1
                    outBuf[outIdx] = UInt8((v >> 16) & 0xFF); outIdx += 1
                    outBuf[outIdx] = UInt8((v >> 24) & 0xFF); outIdx += 1
                }
            }
        }
        return out
    }

    // MARK: - ROMix (RFC 7914 §5)

    private static func romix(block: [UInt8], n: Int, r: Int) -> [UInt8] {
        var x = block
        var v = [[UInt8]]()
        v.reserveCapacity(n)
        for _ in 0..<n {
            v.append(x)
            x = blockMix(block: x, r: r)
        }
        let lastStart = (2 * r - 1) * 64
        for _ in 0..<n {
            // Read 4 bytes from position (2r-1)*64 of x as little-endian U32 → integerify.
            let intg = UInt32(x[lastStart]) |
                       (UInt32(x[lastStart + 1]) << 8) |
                       (UInt32(x[lastStart + 2]) << 16) |
                       (UInt32(x[lastStart + 3]) << 24)
            let j = Int(intg) % n
            // x = x XOR V[j]
            var nx = [UInt8](repeating: 0, count: x.count)
            nx.withUnsafeMutableBufferPointer { nxBuf in
                x.withUnsafeBufferPointer { xBuf in
                    v[j].withUnsafeBufferPointer { vBuf in
                        for i in 0..<xBuf.count { nxBuf[i] = xBuf[i] ^ vBuf[i] }
                    }
                }
            }
            x = blockMix(block: nx, r: r)
        }
        return x
    }
}
