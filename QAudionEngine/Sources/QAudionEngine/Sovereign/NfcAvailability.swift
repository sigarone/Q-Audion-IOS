import Foundation
#if canImport(CoreNFC) && os(iOS)
import CoreNFC
#endif

/// Whether this device can read NFC tags (an iPad, for instance, cannot).
///
/// The NFC entry points and the exchange consult this value instead of
/// calling CoreNFC directly, so the answer can be replaced in tests:
/// `NfcAvailability { false }` behaves like a device without NFC.
public struct NfcAvailability {
    private let check: () -> Bool

    public init(_ check: @escaping () -> Bool) {
        self.check = check
    }

    /// `true` when an NFC reader session can be started.
    public var isAvailable: Bool { check() }

    /// The answer of the device this code is running on.
    public static let device = NfcAvailability { NfcAvailability.deviceReadsTags() }

    /// Neutral, localized line shown instead of the NFC actions when
    /// `isAvailable` is `false`.
    public static var unavailableMessage: String {
        String(localized: "nfc.unavailable", defaultValue: "NFC non disponibile su questo dispositivo", comment: "Shown in place of the NFC pairing actions on a device that cannot read NFC tags.")
    }

    private static func deviceReadsTags() -> Bool {
        #if canImport(CoreNFC) && os(iOS)
        return NFCTagReaderSession.readingAvailable
        #else
        return false
        #endif
    }
}
