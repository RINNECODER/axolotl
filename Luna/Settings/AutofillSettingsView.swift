import SwiftUI

/// Settings → Passwords & Import → Autofill: address and payment-card switches, and the saved entries.
struct AutofillSettingsView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var profileId: UUID = ProfileManager.shared.lastActiveProfileId
    @AppStorage(AutofillPrefs.addresses) private var addressesOn = true
    @AppStorage(AutofillPrefs.cards) private var cardsOn = true

    var body: some View {
        Group {
            SettingsCard(footer: "Luna offers saved addresses and cards when you click a form field, and offers to save new ones when you submit a form (never in private windows). Changes apply to tabs opened afterwards.") {
                SettingsMenuRow("Profile", selection: $profileId, options: profileManager.profiles.map {
                    .init($0.id, $0.name, image: ProfileAvatar.image(for: $0, size: 16))
                })
                SettingsToggleRow("Addresses", subtitle: "Fill and save shipping and contact details.", isOn: $addressesOn)
                SettingsToggleRow("Payment methods", subtitle: "Fill and save cards on secure (https) pages. Filling asks for Touch ID.",
                                  isOn: $cardsOn)
            }
            AutofillEntriesView(store: AutofillStore.forProfile(profileId)).id(profileId)
        }
    }
}

private struct AutofillEntriesView: View {
    @ObservedObject var store: AutofillStore
    @State private var editingAddress: AutofillAddress?
    @State private var editingCard: AutofillCard?
    @State private var revealed: [UUID: String] = [:]

    var body: some View {
        SettingsCard("Payment methods", footer: "Card numbers are kept in your Keychain. Security codes (CVC) are never saved.") {
            ForEach(store.cards) { card in
                SettingsRow(card.title, subtitle: [card.cardholder, card.expiry].filter { !$0.isEmpty }.joined(separator: " · "),
                            icon: "creditcard") {
                    Text(revealed[card.id] ?? card.masked)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button { toggleReveal(card) } label: { Image(systemName: revealed[card.id] == nil ? "eye" : "eye.slash") }
                        .buttonStyle(.borderless)
                        .help(revealed[card.id] == nil ? "Show card number" : "Hide card number")
                        .accessibilityLabel(revealed[card.id] == nil ? "Show card number" : "Hide card number")
                    Button("Edit") { editingCard = card }
                    Button(role: .destructive) { store.delete(card) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete card")
                        .accessibilityLabel("Delete card")
                }
            }
            SettingsRow(store.cards.isEmpty ? "No saved cards" : "Add another card") {
                Button("Add Card…") { editingCard = AutofillCard() }
            }
        }
        SettingsCard("Addresses") {
            ForEach(store.addresses) { address in
                SettingsRow(address.name.isEmpty ? "Address" : address.name, subtitle: address.summary, icon: "house") {
                    Button("Edit") { editingAddress = address }
                    Button(role: .destructive) { store.delete(address) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete address")
                        .accessibilityLabel("Delete address")
                }
            }
            SettingsRow(store.addresses.isEmpty ? "No saved addresses" : "Add another address") {
                Button("Add Address…") { editingAddress = AutofillAddress() }
            }
        }
        .sheet(item: $editingAddress) { address in
            AddressEditor(address: address, onSave: { store.save($0); editingAddress = nil }, onCancel: { editingAddress = nil })
        }
        .sheet(item: $editingCard) { card in
            CardEditor(card: card, isNew: !store.cards.contains { $0.id == card.id },
                       onSave: { store.save($0, number: $1); revealed[$0.id] = nil; editingCard = nil },
                       onCancel: { editingCard = nil })
        }
    }

    private func toggleReveal(_ card: AutofillCard) {
        if revealed[card.id] != nil { revealed[card.id] = nil; return }
        Task {
            guard await PasswordVault.shared.unlock(reason: "show your card \(card.masked)") else { return }
            revealed[card.id] = store.number(for: card)
        }
    }
}

private struct AddressEditor: View {
    @State var address: AutofillAddress
    let onSave: (AutofillAddress) -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            TextField("Name", text: $address.name)
            TextField("Organization", text: $address.organization)
            TextField("Street address", text: $address.street, axis: .vertical).lineLimit(1...3)
            TextField("City", text: $address.city)
            TextField("State / Province", text: $address.state)
            TextField("ZIP / Postal code", text: $address.postalCode)
            TextField("Country", text: $address.country)
            TextField("Phone", text: $address.phone)
            TextField("Email", text: $address.email)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(address) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct CardEditor: View {
    @State var card: AutofillCard
    let isNew: Bool
    /// The new number, or nil to keep the stored one.
    let onSave: (AutofillCard, String?) -> Void
    let onCancel: () -> Void
    @State private var number = ""

    private var numberOK: Bool { number.isEmpty ? !isNew : AutofillCard.isLuhnValid(number) }

    var body: some View {
        Form {
            TextField("Card number", text: $number, prompt: Text(isNew ? "1234 5678 9012 3456" : "\(card.masked) (unchanged)"))
            if !number.isEmpty && !numberOK {
                Text("That card number isn't valid.").font(.system(size: 11)).foregroundStyle(.red)
            }
            TextField("Name on card", text: $card.cardholder)
            Picker("Expiry month", selection: $card.expMonth) {
                Text("—").tag(0)
                ForEach(1...12, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            Picker("Expiry year", selection: $card.expYear) {
                Text("—").tag(0)
                let year = Calendar.current.component(.year, from: Date())
                ForEach(Array(Set((year...(year + 15)) + [card.expYear].filter { $0 > 0 })).sorted(), id: \.self) { Text(String($0)).tag($0) }
            }
            TextField("Nickname", text: $card.nickname)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(card, number.isEmpty ? nil : number) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!numberOK)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
