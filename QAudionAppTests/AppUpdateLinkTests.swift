import XCTest
@testable import QAudionApp

/// The update screen's "Apri App Store" button opens only App Store pages, whatever link the update
/// endpoint returns.
final class AppUpdateLinkTests: XCTestCase {

    private func link(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    func testAppStoreLinksAreAccepted() {
        XCTAssertTrue(AppUpdateChecker.isAppStoreLink(link("itms-apps://apps.apple.com/app/id1234567890")))
        XCTAssertTrue(AppUpdateChecker.isAppStoreLink(link("itms-apps://itunes.apple.com/app/id1234567890")))
        XCTAssertTrue(AppUpdateChecker.isAppStoreLink(link("itms-appss://apps.apple.com/app/id1234567890")))
        XCTAssertTrue(AppUpdateChecker.isAppStoreLink(link("https://apps.apple.com/it/app/id1234567890")))
        XCTAssertTrue(AppUpdateChecker.isAppStoreLink(link("HTTPS://APPS.APPLE.COM/app/id1234567890")))
    }

    func testEverythingElseIsRefused() {
        XCTAssertFalse(AppUpdateChecker.isAppStoreLink(link("https://example.com/download")))
        XCTAssertFalse(AppUpdateChecker.isAppStoreLink(link("http://apps.apple.com/app/id1234567890")))
        XCTAssertFalse(AppUpdateChecker.isAppStoreLink(link("https://apps.apple.com.example.com/app")))
        XCTAssertFalse(AppUpdateChecker.isAppStoreLink(link("https://itunes.apple.com/app/id1234567890")))
        XCTAssertFalse(AppUpdateChecker.isAppStoreLink(link("itms-services://?action=download-manifest&url=https://example.com/m.plist")))
        XCTAssertFalse(AppUpdateChecker.isAppStoreLink(link("itms-apps://example.com/app")))
        XCTAssertFalse(AppUpdateChecker.isAppStoreLink(link("javascript:alert(1)")))
        XCTAssertFalse(AppUpdateChecker.isAppStoreLink(link("/relative/path")))
    }
}
