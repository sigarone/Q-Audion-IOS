import XCTest
@testable import QAudionApp
import QAudionEngine

/// Nome della piattaforma e simbolo SF mostrati per ogni dispositivo collegato.
/// Funzioni pure: nessuno stato, nessun accesso a rete o Keychain.
final class DeviceSymbolTests: XCTestCase {

    func testDesktopPlatformTagIsDesktop() {
        XCTAssertEqual(EnhancedDeviceItem.platformTag(for: .desktop, deviceName: "PC"),
                       "Desktop")
    }

    func testPhoneIconIsIPhoneOnlyForIOSPlatform() {
        XCTAssertEqual(EnhancedDeviceItem.kindIcon(kind: .phonePrimary, platformTag: "Android"),
                       "candybarphone")
        XCTAssertEqual(EnhancedDeviceItem.kindIcon(kind: .phonePrimary, platformTag: "iOS"),
                       "iphone")
    }

    func testDesktopIconIsDisplay() {
        XCTAssertEqual(EnhancedDeviceItem.kindIcon(kind: .desktop, platformTag: "Desktop"),
                       "display")
    }

    func testTabletIconOnNonApplePlatformIsGeneric() {
        XCTAssertEqual(EnhancedDeviceItem.kindIcon(kind: .tablet, platformTag: "Android"),
                       "rectangle.portrait")
    }

    func testWatchIconOnNonApplePlatformIsGeneric() {
        XCTAssertEqual(EnhancedDeviceItem.kindIcon(kind: .watch, platformTag: "Android"),
                       "clock")
    }
}
