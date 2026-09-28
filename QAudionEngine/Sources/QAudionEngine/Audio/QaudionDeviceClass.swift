import Foundation

/// W-M150ADAPTIVECOMPLEXITY (2026-09-29) — "old device" detection for
/// `AdaptiveOpusComplexityPolicy`/`AdaptiveOpusDecoderComplexityPolicy`'s
/// `DeviceCapabilityHint.isOldDevice`. The plan's iOS line is "A11 o
/// precedente" (iPhone 8 / 8 Plus / X and earlier) — a CHIP-GENERATION
/// signal, unlike Android's RAM/core-count one, because iOS exposes no
/// public low-RAM-device API. There is also no public chip-generation API;
/// every app that needs one (this codebase included, nothing already did)
/// reads the same `hw.machine` sysctl identifier and matches it against a
/// hand-maintained table — the mechanism below, not a guess.
public enum QaudionDeviceClass {

    /// iPhone hardware identifiers from A9 (iPhone 6s) through A11 (iPhone
    /// 8/8 Plus/X inclusive) — the newest chip generation this table treats
    /// as "old". iPhone11,x (XS/XR) is the first A12 device and is
    /// deliberately NOT in this set.
    ///
    /// Not a full historical iPhone table (nothing older than the 6s is
    /// listed — a device that old failing `isOldDevice` would only cost it
    /// too-high a ceiling, not a correctness bug, and this fleet's stated
    /// floor is iOS 16 anyway per `Package.swift`'s `platforms: [.iOS(.v16)]`,
    /// which the 6s/SE-1st-gen (A9) cannot run — kept here only because they
    /// share the A9 identifier prefix with nothing that DOES support iOS 16,
    /// so listing them is free and future-proofs nothing incorrectly).
    static let a11OrEarlierIdentifiers: Set<String> = [
        "iPhone8,1", "iPhone8,2", "iPhone8,4",              // 6s, 6s Plus, SE (1st gen) — A9
        "iPhone9,1", "iPhone9,2", "iPhone9,3", "iPhone9,4", // 7, 7 Plus — A10
        "iPhone10,1", "iPhone10,2", "iPhone10,3",           // 8, 8 Plus, X (CDMA/GSM variants) — A11
        "iPhone10,4", "iPhone10,5", "iPhone10,6"            // 8, 8 Plus, X (GSM-only variants) — A11
    ]

    /// Pure lookup — the half a test can call without a real device.
    static func isA11OrEarlier(machineIdentifier: String) -> Bool {
        a11OrEarlierIdentifiers.contains(machineIdentifier)
    }

    /// The live `hw.machine` sysctl string (e.g. "iPhone15,2"). `nil` only
    /// if the syscall itself fails, which does not happen on real iOS
    /// hardware — the fallback below reads as "not old" (capable side),
    /// same fail-open reasoning `isA11OrEarlier()` documents.
    static func currentMachineIdentifier() -> String? {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return nil }
        return withUnsafePointer(to: &systemInfo.machine) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: systemInfo.machine)) {
                String(cString: $0)
            }
        }
    }

    /// `true` only for an identifier this table recognizes as A11-or-older.
    /// An unrecognized identifier (a simulator's own machine string, a real
    /// device newer than this table's newest entry, or a device this table
    /// simply never learned about) returns `false` — fails toward the
    /// CAPABLE side, matching the owner's explicit instruction (2026-09-29)
    /// not to let an unrecognized device be capped for no reason.
    public static func isA11OrEarlier() -> Bool {
        guard let machine = currentMachineIdentifier() else { return false }
        return isA11OrEarlier(machineIdentifier: machine)
    }
}
