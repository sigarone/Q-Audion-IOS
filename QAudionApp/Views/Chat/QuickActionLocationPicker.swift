import SwiftUI

/// The sheet of the "Condividi posizione" quick action of the icon: one contact to pick, then the chat of that contact opens with
/// the share sheet of location (the request goes through `LocationShareIntentRouter.handle`, the same path as the app intent).
/// Nothing is sent from here: the user confirms in the share sheet.
///
/// The list is the one the app intent lists: no blocked contact, nothing while signed out or behind the app lock. No name, id or
/// position is logged.
struct QuickActionLocationPicker: View {
    let onDone: () -> Void

    @State private var searchText: String = ""
    @State private var contacts: [LocationShareContactFacts] = []

    private var shown: [LocationShareContactFacts] {
        let sorted = contacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return LocationShareIntentPolicy.matching(sorted, query: searchText)
    }

    var body: some View {
        NavigationStack {
            Group {
                if contacts.isEmpty {
                    Text("Nessun contatto disponibile")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(shown, id: \.userId) { contact in
                        Button {
                            pick(contact)
                        } label: {
                            HStack {
                                Text(contact.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "location.fill")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .searchable(text: $searchText)
                }
            }
            .navigationTitle(Text("Condividi posizione"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { onDone() }
                }
            }
        }
        .onAppear { contacts = LocationShareIntentRouter.listableContacts() }
    }

    private func pick(_ contact: LocationShareContactFacts) {
        _ = LocationShareIntentRouter.handle(contactId: contact.userId, mode: .instant)
        onDone()
    }
}
