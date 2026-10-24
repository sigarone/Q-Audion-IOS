import SwiftUI

/// The sheet of the "Condividi posizione" quick action of the icon: one contact to pick, then the chat of that contact opens with
/// the share sheet of location. The pick is reported to the list (`onPick`), which closes this sheet first and hands the request
/// to the chat (`LocationShareIntentRouter.handle`, the same path as the app intent) once the sheet is gone, so the dismissal and
/// the push of the chat never run together. Nothing is sent from here: the user confirms in the share sheet.
///
/// The list is the one the app intent lists: no blocked contact, nothing while signed out or behind the app lock. No name, id or
/// position is logged.
struct QuickActionLocationPicker: View {
    let onPick: (String) -> Void
    let onDone: () -> Void

    @State private var searchText: String = ""
    @State private var contacts: [LocationShareContactFacts] = []

    private var shown: [LocationShareContactFacts] {
        let sorted = contacts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return LocationShareIntentPolicy.matching(sorted, query: searchText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if contacts.isEmpty {
                    Text("Nessun contatto disponibile")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // A plain field, not `.searchable`: the search controller of a sheet is torn down while the chat is pushed
                    // underneath, and its bar views then belong to two hierarchies.
                    TextField("Cerca contatti", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
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
        onPick(contact.userId)
    }
}
