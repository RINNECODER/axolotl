import Combine
import CryptoKit
import Foundation
import Security

/// Settings → Passwords & Import → Autofill switches. Both default on; with both off
/// no autofill script or message handler is added to tabs and no store is loaded.
enum AutofillPrefs {
    static let addresses = "axolotl_autofill_addresses"
    static let cards = "axolotl_autofill_cards"

    static func isOn(_ key: String, _ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static var anyOn: Bool { isOn(addresses) || isOn(cards) }
}

/// What a form field asks for. `ccCSC` is recognized only so it is never filled or saved.
enum AutofillField: String, CaseIterable {
    case name, givenName, familyName, organization, street, street2, city, state, postalCode, country, phone, email
    case ccName, ccNumber, ccExp, ccExpMonth, ccExpYear, ccCSC

    var isCard: Bool { rawValue.hasPrefix("cc") }

    private static let autocompleteTokens: [String: AutofillField] = [
        "name": .name, "given-name": .givenName, "family-name": .familyName, "organization": .organization,
        "street-address": .street, "address-line1": .street, "address-line2": .street2,
        "address-level2": .city, "address-level1": .state, "postal-code": .postalCode,
        "country": .country, "country-name": .country, "tel": .phone, "tel-national": .phone, "email": .email,
        "cc-name": .ccName, "cc-number": .ccNumber, "cc-exp": .ccExp, "cc-exp-month": .ccExpMonth,
        "cc-exp-year": .ccExpYear, "cc-csc": .ccCSC,
    ]

    /// Most specific first: the first pattern that matches the field's name/id/label/placeholder wins.
    private static let heuristics: [(String, AutofillField?)] = [
        (#"user.?name|login|search|captcha|coupon|promo|password"#, nil),
        (#"cvc|cvv|csc|security.?code|card.?verification"#, .ccCSC),
        (#"name.?on.?card|card.?holder|cc.?name"#, .ccName),
        (#"card.?num|cc.?num|credit.?card|debit.?card"#, .ccNumber),
        (#"mm.?/.?yy"#, .ccExp),
        (#"(exp|expiry|expiration).*(month|mm\b)|cc.?month"#, .ccExpMonth),
        (#"(exp|expiry|expiration).*(year|yy)|cc.?year"#, .ccExpYear),
        (#"exp(iry|iration)?.?(date)?\b"#, .ccExp),
        (#"e.?mail"#, .email),
        (#"phone|mobile|\btel\b"#, .phone),
        (#"company|organi[sz]ation|business"#, .organization),
        (#"address.?(line)?.?2|addr2|\bapt|suite|\bunit\b"#, .street2),
        (#"zip|postal|post.?code"#, .postalCode),
        (#"address|street|addr"#, .street),
        (#"city|town|locality|suburb"#, .city),
        (#"state|province|region|county"#, .state),
        (#"country"#, .country),
        (#"first.?name|given.?name|fname|forename"#, .givenName),
        (#"last.?name|surname|family.?name|lname"#, .familyName),
        (#"name"#, .name),
    ]

    /// Classifies a field: its `autocomplete` attribute first (ignoring section-/shipping/billing
    /// prefixes), then name/id/label/placeholder heuristics, then the input type.
    static func classify(autocomplete: String = "", name: String = "", id: String = "", label: String = "",
                         placeholder: String = "", type: String = "") -> AutofillField? {
        let tokens = autocomplete.lowercased().split(separator: " ")
        if let last = tokens.last {
            if let field = autocompleteTokens[String(last)] { return field }
            // "username", "current-password", "one-time-code"… are explicit non-autofill fields.
            if last != "on" && last != "off" { return nil }
        }
        let text = [name, id, label, placeholder].joined(separator: " ").lowercased()
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            for (pattern, field) in heuristics where text.range(of: pattern, options: .regularExpression) != nil {
                return field
            }
        }
        switch type.lowercased() {
        case "email": return .email
        case "tel": return .phone
        default: return nil
        }
    }
}

/// A saved address; plain text only inside the encrypted autofill file.
struct AutofillAddress: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "", organization = "", street = "", city = "", state = "", postalCode = "", country = ""
    var phone = "", email = ""

    var summary: String {
        [name, street.components(separatedBy: "\n").first ?? "", city].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    func value(for field: AutofillField) -> String? {
        let lines = street.components(separatedBy: "\n")
        let words = name.split(separator: " ").map(String.init)
        switch field {
        case .name: return name
        case .givenName: return words.count > 1 ? words.dropLast().joined(separator: " ") : name
        case .familyName: return words.count > 1 ? words.last : nil
        case .organization: return organization
        case .street: return lines.first
        case .street2: return lines.dropFirst().joined(separator: " ")
        case .city: return city
        case .state: return state
        case .postalCode: return postalCode
        case .country: return country
        case .phone: return phone
        case .email: return email
        default: return nil
        }
    }

    /// Same place, ignoring case and spacing (for "already saved?").
    func isSamePlace(as other: AutofillAddress) -> Bool {
        func key(_ a: AutofillAddress) -> String {
            (a.street + "|" + a.postalCode).lowercased().filter { !$0.isWhitespace }
        }
        return key(self) == key(other)
    }
}

/// A saved card. The number lives only in the Keychain; the CVC is never stored.
struct AutofillCard: Codable, Identifiable, Hashable {
    var id = UUID()
    var cardholder = "", last4 = "", expMonth = 0, expYear = 0, nickname = ""

    var masked: String { Self.mask(last4) }
    var title: String { nickname.isEmpty ? masked : "\(nickname) \(masked)" }
    var expiry: String { expMonth > 0 ? String(format: "%02d/%02d", expMonth, expYear % 100) : "" }

    static func mask(_ number: String) -> String { "•••• " + String(number.filter(\.isNumber).suffix(4)) }

    /// Luhn checksum on a 12–19 digit number (spaces and dashes allowed).
    static func isLuhnValid(_ number: String) -> Bool {
        let digits = number.filter { !$0.isWhitespace && $0 != "-" }
        guard (12...19).contains(digits.count), digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            var d = ch.wholeNumberValue ?? 0
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    func value(for field: AutofillField, number: String) -> String? {
        switch field {
        case .ccName: return cardholder
        case .ccNumber: return number
        case .ccExp: return expiry
        case .ccExpMonth: return expMonth > 0 ? String(format: "%02d", expMonth) : nil
        case .ccExpYear: return expYear > 0 ? String(expYear) : nil
        default: return nil // never the CVC
        }
    }
}

/// What a submitted form would save: an address and/or a card (number kept apart, CVC dropped).
struct AutofillCandidate: Equatable {
    var address: AutofillAddress?
    var card: AutofillCard?
    var cardNumber: String?

    init(fields: [(AutofillField, String)]) {
        var a = AutofillAddress(), c = AutofillCard(), given = "", family = "", street2 = "", number = ""
        for (field, raw) in fields {
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { continue }
            switch field {
            case .name: a.name = v
            case .givenName: given = v
            case .familyName: family = v
            case .organization: a.organization = v
            case .street: a.street = v
            case .street2: street2 = v
            case .city: a.city = v
            case .state: a.state = v
            case .postalCode: a.postalCode = v
            case .country: a.country = v
            case .phone: a.phone = v
            case .email: a.email = v
            case .ccName: c.cardholder = v
            case .ccNumber: number = v.filter(\.isNumber)
            case .ccExp:
                let parts = v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if parts.count >= 2 { c.expMonth = parts[0]; c.expYear = parts[1] }
            case .ccExpMonth: c.expMonth = Int(v.filter(\.isNumber)) ?? 0
            case .ccExpYear: c.expYear = Int(v.filter(\.isNumber)) ?? 0
            case .ccCSC: break
            }
        }
        if a.name.isEmpty { a.name = [given, family].filter { !$0.isEmpty }.joined(separator: " ") }
        if !street2.isEmpty { a.street += "\n" + street2 }
        if c.expYear > 0 && c.expYear < 100 { c.expYear += 2000 }
        if !(1...12).contains(c.expMonth) { c.expMonth = 0 }
        if !a.street.isEmpty && !(a.postalCode.isEmpty && a.city.isEmpty) { address = a }
        if AutofillCard.isLuhnValid(number) {
            c.last4 = String(number.suffix(4))
            card = c
            cardNumber = number
        }
    }

}

/// Saved addresses and cards for one profile. Addresses and card details are an AES-GCM
/// encrypted `autofill.json` in the profile folder (key in the Keychain); card numbers are
/// Keychain items. Everything stays on this Mac.
@MainActor
final class AutofillStore: ObservableObject {
    private struct Saved: Codable { var addresses: [AutofillAddress] = []; var cards: [AutofillCard] = [] }

    @Published private(set) var addresses: [AutofillAddress] = []
    @Published private(set) var cards: [AutofillCard] = []
    private let fileURL: URL
    private let keychain: KeychainStore
    private let profile: UUID
    static let keyService = "com.axolotl.autofill.key"
    static let cardService = "com.axolotl.autofill.card"

    init(fileURL: URL, profile: UUID, keychain: KeychainStore = .shared) {
        self.fileURL = fileURL
        self.profile = profile
        self.keychain = keychain
        if let sealed = try? Data(contentsOf: fileURL), let key = loadKey(create: false),
           let box = try? AES.GCM.SealedBox(combined: sealed), let data = try? AES.GCM.open(box, using: key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            addresses = saved.addresses
            cards = saved.cards
        }
    }

    nonisolated deinit {}

    private static var stores: [UUID: AutofillStore] = [:]

    static func forProfile(_ id: UUID) -> AutofillStore {
        if let store = stores[id] { return store }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Axolotl/Profiles/\(id.uuidString)", isDirectory: true)
        let store = AutofillStore(fileURL: dir.appendingPathComponent("autofill.json"), profile: id)
        stores[id] = store
        return store
    }

    /// Removes a deleted profile's card numbers and file key (its folder goes with the profile).
    static func deleteAll(profile: UUID, keychain: KeychainStore = .shared) {
        stores[profile] = nil
        for service in [keyService, cardService] {
            _ = keychain.delete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                 kSecAttrLabel as String: profile.uuidString], sync: .deviceOnly)
        }
    }

    // MARK: Keychain

    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func readItem(_ service: String, _ account: String) -> Data? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return keychain.copyMatching(q, sync: .deviceOnly).1 as? Data
    }

    private func writeItem(_ service: String, _ account: String, _ data: Data) -> Bool {
        _ = keychain.delete(query(service, account), sync: .deviceOnly)
        var add = query(service, account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = profile.uuidString // lets deleteAll find this profile's items
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return keychain.add(add, sync: .deviceOnly) == errSecSuccess
    }

    private func loadKey(create: Bool) -> SymmetricKey? {
        if let data = readItem(Self.keyService, profile.uuidString) { return SymmetricKey(data: data) }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        return writeItem(Self.keyService, profile.uuidString, key.withUnsafeBytes { Data($0) }) ? key : nil
    }

    private func persist() {
        guard let key = loadKey(create: true),
              let data = try? JSONEncoder().encode(Saved(addresses: addresses, cards: cards)),
              let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    // MARK: Addresses

    func save(_ address: AutofillAddress) {
        if let i = addresses.firstIndex(where: { $0.id == address.id }) { addresses[i] = address } else { addresses.append(address) }
        persist()
    }

    func delete(_ address: AutofillAddress) {
        addresses.removeAll { $0.id == address.id }
        persist()
    }

    func hasAddress(like address: AutofillAddress) -> Bool { addresses.contains { $0.isSamePlace(as: address) } }

    // MARK: Cards

    /// Saves card details, and the number when given (nil keeps the stored one).
    func save(_ card: AutofillCard, number: String?) {
        var card = card
        if let number {
            let digits = number.filter(\.isNumber)
            guard writeItem(Self.cardService, card.id.uuidString, Data(digits.utf8)) else { return }
            card.last4 = String(digits.suffix(4))
        }
        if let i = cards.firstIndex(where: { $0.id == card.id }) { cards[i] = card } else { cards.append(card) }
        persist()
    }

    func delete(_ card: AutofillCard) {
        _ = keychain.delete(query(Self.cardService, card.id.uuidString), sync: .deviceOnly)
        cards.removeAll { $0.id == card.id }
        persist()
    }

    /// The full number. Callers unlock first (`PasswordVault.shared.unlock`), as for passwords.
    func number(for card: AutofillCard) -> String? {
        readItem(Self.cardService, card.id.uuidString).flatMap { String(data: $0, encoding: .utf8) }
    }

    func hasCard(number: String) -> Bool {
        let digits = number.filter(\.isNumber)
        return cards.contains { $0.last4 == String(digits.suffix(4)) && self.number(for: $0) == digits }
    }
}
