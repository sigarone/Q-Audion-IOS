import XCTest
@testable import QAudionEngine

final class ContactsListViewModelTests: XCTestCase {

    func test_mockIsDeterministic() {
        XCTAssertEqual(ContactsListViewModel.mock, ContactsListViewModel.mock)
    }

    func test_mockHas3Items() {
        XCTAssertEqual(ContactsListViewModel.mock.items.count, 3)
    }

    func test_filteredItems_emptyQuery_returnsAll() {
        XCTAssertEqual(ContactsListViewModel.mock.filteredItems.count, 3)
    }

    func test_filteredItems_partialMatch() {
        let vm = ContactsListViewModel(
            items: ContactsListViewModel.mock.items,
            searchQuery: "ali"
        )
        XCTAssertEqual(vm.filteredItems.count, 1)
        XCTAssertEqual(vm.filteredItems.first?.userId, "user-alice")
    }

    func test_filteredItems_caseInsensitive() {
        let vm = ContactsListViewModel(
            items: ContactsListViewModel.mock.items,
            searchQuery: "BOB"
        )
        XCTAssertEqual(vm.filteredItems.count, 1)
        XCTAssertEqual(vm.filteredItems.first?.userId, "user-bob")
    }

    func test_filteredItems_noMatch_returnsEmpty() {
        let vm = ContactsListViewModel(
            items: ContactsListViewModel.mock.items,
            searchQuery: "xyz"
        )
        XCTAssertTrue(vm.filteredItems.isEmpty)
    }

    func test_mockHasMixedVerificationStatus() {
        let verified = ContactsListViewModel.mock.items.filter { $0.isVerified }
        let unverified = ContactsListViewModel.mock.items.filter { !$0.isVerified }
        XCTAssertGreaterThan(verified.count, 0)
        XCTAssertGreaterThan(unverified.count, 0)
    }
}
