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
}
