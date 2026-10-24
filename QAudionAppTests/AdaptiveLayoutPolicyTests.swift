import XCTest
import CoreGraphics
@testable import QAudionApp

/// The layout decisions for the sizes an iPhone can take (folded and unfolded foldable iPhone, Split View, tablets):
/// which navigation the shell uses, when the chat list and the open chat sit side by side, how a call screen is arranged,
/// how large its avatar ring is, and what identifies the chat that is open.
///
/// The views read these rules and nothing else decides a layout, so the rules are pinned here as pure functions. Wired
/// into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class AdaptiveLayoutPolicyTests: XCTestCase {

    // MARK: - Shell

    func testACompactWindowAlwaysKeepsTheTabBar() {
        for width: CGFloat in [320, 393, 430, 678, 1024] {
            XCTAssertEqual(
                QAudionAdaptive.shellStyle(horizontalRegular: false, width: width), .tabs, "width \(width)")
        }
    }

    func testARegularWindowGetsASidebarOnlyWhenItIsWideEnough() {
        XCTAssertEqual(QAudionAdaptive.shellStyle(horizontalRegular: true, width: 626), .tabs)
        XCTAssertEqual(QAudionAdaptive.shellStyle(horizontalRegular: true, width: 699), .tabs)
        XCTAssertEqual(QAudionAdaptive.shellStyle(horizontalRegular: true, width: 700), .sidebar)
        XCTAssertEqual(QAudionAdaptive.shellStyle(horizontalRegular: true, width: 1024), .sidebar)
    }

    func testAnUnknownWidthLeavesTheDecisionToTheSizeClass() {
        XCTAssertEqual(
            QAudionAdaptive.shellStyle(horizontalRegular: true, width: CGFloat.greatestFiniteMagnitude), .sidebar)
        XCTAssertEqual(
            QAudionAdaptive.shellStyle(horizontalRegular: false, width: CGFloat.greatestFiniteMagnitude), .tabs)
    }

    // MARK: - Chats

    func testTwoPanesNeedARegularWindowAndEnoughWidth() {
        XCTAssertFalse(QAudionAdaptive.chatsAreTwoPane(horizontalRegular: false, width: 900))
        XCTAssertFalse(QAudionAdaptive.chatsAreTwoPane(horizontalRegular: true, width: 559))
        XCTAssertTrue(QAudionAdaptive.chatsAreTwoPane(horizontalRegular: true, width: 560))
        XCTAssertTrue(QAudionAdaptive.chatsAreTwoPane(horizontalRegular: true, width: 1024))
    }

    func testTheListColumnStaysBetweenItsLimits() {
        XCTAssertEqual(QAudionAdaptive.listPaneWidth(totalWidth: 560), 300, accuracy: 0.001)
        XCTAssertEqual(QAudionAdaptive.listPaneWidth(totalWidth: 800), 336, accuracy: 0.001)
        XCTAssertEqual(QAudionAdaptive.listPaneWidth(totalWidth: 2000), 380, accuracy: 0.001)
        XCTAssertEqual(QAudionAdaptive.listPaneWidth(totalWidth: 100), 300, accuracy: 0.001)
    }

    func testTheListColumnLeavesRoomForTheChat() {
        for total: CGFloat in [560, 626, 744, 820, 1024, 1366] {
            let list = QAudionAdaptive.listPaneWidth(totalWidth: total)
            XCTAssertGreaterThanOrEqual(total - list, 260, "width \(total)")
        }
    }

    // MARK: - Call screens

    func testACallScreenOfPhoneSizeIsOneColumn() {
        XCTAssertEqual(QAudionAdaptive.callArrangement(size: CGSize(width: 393, height: 852)), .stacked)
        XCTAssertEqual(QAudionAdaptive.callArrangement(size: CGSize(width: 375, height: 667)), .stacked)
        XCTAssertEqual(QAudionAdaptive.callArrangement(size: CGSize(width: 626, height: 890)), .stacked)
    }

    func testAShortOrWideCallScreenIsTwoColumns() {
        // A phone on its side.
        XCTAssertEqual(QAudionAdaptive.callArrangement(size: CGSize(width: 852, height: 393)), .sideBySide)
        // Too short for a column of ring, name and buttons, whatever the width.
        XCTAssertEqual(QAudionAdaptive.callArrangement(size: CGSize(width: 393, height: 500)), .sideBySide)
        // Wider than tall and wide enough for two columns.
        XCTAssertEqual(QAudionAdaptive.callArrangement(size: CGSize(width: 900, height: 700)), .sideBySide)
    }

    func testANarrowWindowThatIsWiderThanTallStaysOneColumnWhileItIsTallEnough() {
        XCTAssertEqual(QAudionAdaptive.callArrangement(size: CGSize(width: 540, height: 540)), .stacked)
        XCTAssertEqual(QAudionAdaptive.callArrangement(size: CGSize(width: 600, height: 560)), .stacked)
    }

    func testTheRingTakesTheRoomItIsGivenWithinItsLimits() {
        XCTAssertEqual(QAudionAdaptive.callRing(verticalRoom: 1000), QAudionAdaptive.CallRingMetrics(ring: 240, avatar: 160))
        XCTAssertEqual(QAudionAdaptive.callRing(verticalRoom: 240).ring, 240, accuracy: 0.001)
        XCTAssertEqual(QAudionAdaptive.callRing(verticalRoom: 180).ring, 180, accuracy: 0.001)
        XCTAssertEqual(QAudionAdaptive.callRing(verticalRoom: 180).avatar, 120, accuracy: 0.001)
        XCTAssertEqual(QAudionAdaptive.callRing(verticalRoom: 40), QAudionAdaptive.CallRingMetrics(ring: 120, avatar: 80))
        XCTAssertEqual(QAudionAdaptive.callRing(verticalRoom: -50).ring, 120, accuracy: 0.001)
    }

    func testTheAvatarAlwaysFitsInsideTheRing() {
        for room: CGFloat in stride(from: 0, through: 400, by: 20) {
            let metrics = QAudionAdaptive.callRing(verticalRoom: room)
            XCTAssertLessThan(metrics.avatar, metrics.ring, "room \(room)")
            XCTAssertGreaterThanOrEqual(metrics.ring, QAudionAdaptive.callRingFloor)
            XCTAssertLessThanOrEqual(metrics.ring, QAudionAdaptive.callRingDesign)
        }
    }

    // MARK: - The open chat

    func testEachChatHasItsOwnIdentity() {
        let one = UUID()
        let other = UUID()
        let a = QAudionChatTarget.conversation(id: one, peerUserId: "u1", peerDisplayName: "A")
        let b = QAudionChatTarget.conversation(id: other, peerUserId: "u2", peerDisplayName: "B")
        let g = QAudionChatTarget.group(id: one, name: "G", memberCount: 3)
        XCTAssertNotEqual(a.id, b.id)
        // The same UUID as a conversation and as a group is not the same chat.
        XCTAssertNotEqual(a.id, g.id)
        XCTAssertNotEqual(a, g)
    }

    func testTheSelectionStartsEmptyAndKeepsWhatItIsGiven() {
        XCTAssertNil(ChatSelectionModel().selected)
        let target = QAudionChatTarget.group(id: UUID(), name: "G", memberCount: 2)
        let model = ChatSelectionModel(selected: target)
        XCTAssertEqual(model.selected, target)
        model.selected = nil
        XCTAssertNil(model.selected)
    }
}
