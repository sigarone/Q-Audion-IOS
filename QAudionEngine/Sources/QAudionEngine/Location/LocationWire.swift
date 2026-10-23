import Foundation

// Location messages (WIRE_SPEC section 14): an instant position (a pin) and a live share that follows the sender for a chosen time.
//
// The Location directory is the FORMAT LIBRARY and the two state machines of the feature, and nothing else: no network, no UI, no
// permission prompt, no persistence of its own (the receiver writes through `LocationShareStore`, which the app implements). It is
// pure logic on engine values, so every known-answer vector of `location-kat.json` runs against it:
//
//  - `LocationWire` (this file): the constants of section 14.1
//  - `LocationCodec`: recognition, validation and the canonical builder of the body (14.3, 14.5)
//  - `LocationConversion`: degrees to E7, accuracy, age, DEC7 and the four open outputs (14.4, 14.9)
//  - `LocationFrameCodec`: the 37-byte live frame, HKDF-SHA256 and AES-256-GCM (14.6.3)
//  - `LocationShareSender`: the sender of one share, the only sealer of its counter (14.6.1)
//  - `LocationShareReceiver`: the receiver of the shares of one conversation, durable through `LocationShareStore` (14.6.2 to 14.7)
//  - `LocationStopControl`: the `loc_stop` variant of the control envelope (14.7)
//  - `LocationLogScrub`: the coordinate rule of every log redactor (14.10)
//
// Nothing in this directory ever logs, prints or describes a position, an accuracy, an `age`, a `sid`, a `k`, a body or a frame: the
// types that hold them print a fixed placeholder as their description.

/// The constants of WIRE_SPEC section 14.1, with the names of the vector file.
public enum LocationWire {

    public static let version: Int64 = 1
    /// `{"qa_loc":` compared as BYTES, never with `hasPrefix` (Swift compares grapheme clusters).
    public static let prefix: [UInt8] = Array(#"{"qa_loc":"#.utf8)
    /// Exclusive: a body is at most 8191 bytes (the limit of section 12.7 and 13); real bodies are under 200.
    public static let maxBytes: Int = 8192
    public static let maxDepth: Int = 4

    public static let latE7Min: Int64 = -900_000_000
    public static let latE7Max: Int64 = 900_000_000
    public static let lonE7Min: Int64 = -1_800_000_000
    public static let lonE7Max: Int64 = 1_800_000_000
    public static let accMin: Int64 = 1
    public static let accMax: Int64 = 65_535
    /// Seconds, receiver bound for the `age` of a body.
    public static let ageMax: Int64 = 3_600
    /// Seconds, builder bound for a pin and a live start.
    public static let buildMaxFixAge: Int64 = 120

    public static let duMin: Int64 = 60
    public static let duMax: Int64 = 86_400
    /// The durations a user interface offers: 15 minutes, 1 hour, 8 hours, 24 hours.
    public static let duPresets: [Int64] = [900, 3_600, 28_800, 86_400]
    /// Seconds of sender clock skew tolerated when computing the end of a live share.
    public static let skew: Int64 = 600

    public static let txInterval: Int64 = 30
    public static let txIntervalLowPower: Int64 = 60
    /// Seconds, the smallest interval between two position frames; a final frame is exempt.
    public static let txMinGap: Int64 = 10
    public static let ivMin: Int64 = 10
    public static let ivMax: Int64 = 600

    public static let frameVersion: UInt8 = 0x01
    public static let frameLength: Int = 37
    public static let framePlaintextLength: Int = 16
    public static let frameAgeMax: Int64 = 65_535
    public static let flagFinal: UInt8 = 0x01
    public static let flagApprox: UInt8 = 0x02

    public static let staleFloor: Int64 = 120
    public static let staleFactor: Int64 = 3
    public static let maxCandidates: Int = 2
    /// `DU_MAX + SKEW`, counted from the arrival of the control.
    public static let tombstoneKeep: Int64 = 87_000
    public static let tombstoneMax: Int = 16
    public static let stopTargetMax: Int = 128

    public static let sidLength: Int = 16
    public static let keyLength: Int = 32
    public static let ephMaxBase64: Int = 256

    /// ASCII labels of section 14.6.3, for frame version 1 only: another version takes labels of its own.
    public static let hkdfInfo: [UInt8] = Array("qa-loc v1 frame key".utf8)
    public static let aadLabel: [UInt8] = Array("qa-loc v1 frame".utf8)

    /// The fixed order of the members of a body (section 14.5).
    public static let memberOrder: [String] = ["qa_loc", "m", "sid", "k", "st", "du", "lat", "lon", "acc", "age", "ap"]
    public static let stopMemberOrder: [String] = ["qa_ctl", "t", "target", "ts"]

    /// The five prefixes user text may not begin with (sections 12.7.1, 13.5 and 14.3.6).
    public static var recognisedPrefixes: [String] {
        MessageReplyCodec.reservedPrefixes.map { String(decoding: $0, as: UTF8.self) }
    }
}
