import XCTest
@testable import QAudionEngine

final class ConversationListViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(ConversationListViewModel.mock, ConversationListViewModel.mock)
    }

    func test_mockHas3Items() {
        XCTAssertEqual(ConversationListViewModel.mock.items.count, 3)
    }

    func test_mockHasGroupConversation() {
        let groups = ConversationListViewModel.mock.items.filter { $0.kind == .group }
        XCTAssertEqual(groups.count, 1)
    }

    func test_filteredItems_pinnedFirst() {
        let mock = ConversationListViewModel.mock
        let filtered = mock.filteredItems
        XCTAssertTrue(filtered.first?.pinned ?? false)
    }

    func test_filteredItems_searchByName() {
        let vm = ConversationListViewModel(
            items: ConversationListViewModel.mock.items,
            searchQuery: "alice"
        )
        XCTAssertEqual(vm.filteredItems.count, 1)
    }

    func test_filteredItems_caseInsensitive() {
        let vm = ConversationListViewModel(
            items: ConversationListViewModel.mock.items,
            searchQuery: "BOB"
        )
        XCTAssertEqual(vm.filteredItems.count, 1)
    }

    func test_filteredItems_noMatch() {
        let vm = ConversationListViewModel(
            items: ConversationListViewModel.mock.items,
            searchQuery: "xyz"
        )
        XCTAssertTrue(vm.filteredItems.isEmpty)
    }

    // MARK: - pinnedNonGroupItems / regularNonGroupItems

    func test_pinnedNonGroupItems_excludesGroupsAndUnpinned() {
        let mock = ConversationListViewModel.mock
        XCTAssertTrue(mock.pinnedNonGroupItems.allSatisfy { $0.pinned && $0.kind != .group })
    }

    func test_regularNonGroupItems_excludesGroupsAndPinned() {
        let mock = ConversationListViewModel.mock
        XCTAssertTrue(mock.regularNonGroupItems.allSatisfy { !$0.pinned && $0.kind != .group })
    }

    func test_pinnedAndRegularNonGroupItems_coverFilteredItemsMinusGroups() {
        let mock = ConversationListViewModel.mock
        let nonGroup = mock.filteredItems.filter { $0.kind != .group }
        XCTAssertEqual(mock.pinnedNonGroupItems.count + mock.regularNonGroupItems.count, nonGroup.count)
        XCTAssertEqual(Set(mock.pinnedNonGroupItems.map(\.conversationId) + mock.regularNonGroupItems.map(\.conversationId)),
                       Set(nonGroup.map(\.conversationId)))
    }

    func test_pinnedAndRegularNonGroupItems_preserveFilteredItemsOrder() {
        let mock = ConversationListViewModel.mock
        let expectedPinnedOrder = mock.filteredItems.filter { $0.kind != .group && $0.pinned }
        let expectedRegularOrder = mock.filteredItems.filter { $0.kind != .group && !$0.pinned }
        XCTAssertEqual(mock.pinnedNonGroupItems.map(\.conversationId), expectedPinnedOrder.map(\.conversationId))
        XCTAssertEqual(mock.regularNonGroupItems.map(\.conversationId), expectedRegularOrder.map(\.conversationId))
    }
}
