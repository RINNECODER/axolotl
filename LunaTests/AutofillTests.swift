import XCTest
@testable import Luna

@MainActor
final class AutofillTests: XCTestCase {
    func testAutocompleteAttributeWinsOverNameHeuristics() {
        XCTAssertEqual(AutofillField.classify(autocomplete: "shipping postal-code", name: "email"), .postalCode)
        XCTAssertEqual(AutofillField.classify(autocomplete: "section-a billing address-line1"), .street)
        XCTAssertEqual(AutofillField.classify(autocomplete: "address-line2"), .street2)
        XCTAssertEqual(AutofillField.classify(autocomplete: "given-name"), .givenName)
        XCTAssertEqual(AutofillField.classify(autocomplete: "cc-number", name: "x"), .ccNumber)
        XCTAssertEqual(AutofillField.classify(autocomplete: "cc-exp-month"), .ccExpMonth)
        XCTAssertEqual(AutofillField.classify(autocomplete: "cc-csc", name: "card_number"), .ccCSC)
        // An explicit non-autofill token is not second-guessed by the name.
        XCTAssertNil(AutofillField.classify(autocomplete: "username", name: "name"))
        // "off" falls through to heuristics, like Chrome.
        XCTAssertEqual(AutofillField.classify(autocomplete: "off", name: "zip"), .postalCode)
    }

    func testNameIdLabelHeuristics() {
        let cases: [(String, AutofillField?)] = [
            ("first_name", .givenName), ("lastName", .familyName), ("Full name", .name),
            ("Email address", .email), ("Address line 2", .street2), ("street_address", .street),
            ("ZIP code", .postalCode), ("city", .city), ("State / Province", .state), ("country", .country),
            ("Phone number", .phone), ("Company", .organization),
            ("Name on card", .ccName), ("cardNumber", .ccNumber), ("Expiration date (MM/YY)", .ccExp),
            ("exp_month", .ccExpMonth), ("exp-year", .ccExpYear), ("CVV", .ccCSC), ("Security code", .ccCSC),
            ("username", nil), ("Search", nil), ("Promo code", nil),
        ]
        for (text, want) in cases {
            XCTAssertEqual(AutofillField.classify(label: text), want, text)
        }
        XCTAssertEqual(AutofillField.classify(type: "email"), .email)
        XCTAssertNil(AutofillField.classify(type: "text"))
    }

    func testLuhnAndMasking() {
        XCTAssertTrue(AutofillCard.isLuhnValid("4242 4242 4242 4242"))
        XCTAssertTrue(AutofillCard.isLuhnValid("5555-5555-5555-4444"))
        XCTAssertTrue(AutofillCard.isLuhnValid("378282246310005"))
        XCTAssertFalse(AutofillCard.isLuhnValid("4242424242424241"))
        XCTAssertFalse(AutofillCard.isLuhnValid("0000"))
        XCTAssertFalse(AutofillCard.isLuhnValid("4242a42424242424"))
        XCTAssertEqual(AutofillCard.mask("4000 0566 5566 5556"), "•••• 5556")
        XCTAssertEqual(AutofillCard(last4: "1881").masked, "•••• 1881")
    }

    func testSubmittedFormBecomesCandidateWithoutCVC() {
        let c = AutofillCandidate(fields: [
            (.givenName, "Ada"), (.familyName, "Lovelace"), (.street, "1 Main St"), (.street2, "Apt 2"),
            (.postalCode, "94110"), (.ccNumber, "4242 4242 4242 4242"), (.ccExp, "07 / 29"), (.ccCSC, "123"),
        ])
        XCTAssertEqual(c.address?.name, "Ada Lovelace")
        XCTAssertEqual(c.address?.street, "1 Main St\nApt 2")
        XCTAssertEqual(c.cardNumber, "4242424242424242")
        XCTAssertEqual(c.card?.last4, "4242")
        XCTAssertEqual(c.card?.expMonth, 7)
        XCTAssertEqual(c.card?.expYear, 2029)
        XCTAssertFalse(String(describing: c).contains("123"))
        // A number failing Luhn is never offered; an address needs a street plus city or postal code.
        let bad = AutofillCandidate(fields: [(.ccNumber, "4242424242424241"), (.street, "1 Main St")])
        XCTAssertNil(bad.card)
        XCTAssertNil(bad.address)
    }

    func testFillValuesSplitNameStreetAndExpiry() {
        let a = AutofillAddress(name: "Ada King Lovelace", street: "1 Main St\nApt 2")
        XCTAssertEqual(a.value(for: .givenName), "Ada King")
        XCTAssertEqual(a.value(for: .familyName), "Lovelace")
        XCTAssertEqual(a.value(for: .street), "1 Main St")
        XCTAssertEqual(a.value(for: .street2), "Apt 2")
        let card = AutofillCard(cardholder: "Ada", last4: "4242", expMonth: 3, expYear: 2031)
        XCTAssertEqual(card.value(for: .ccExp, number: "4242424242424242"), "03/31")
        XCTAssertEqual(card.value(for: .ccExpMonth, number: ""), "03")
        XCTAssertNil(card.value(for: .ccCSC, number: "4242424242424242"))
    }

    func testStoreRoundTripsEncryptedWithNumberOnlyInKeychain() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autofill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("autofill.json")
        let fake = FakeKeychain()
        let keychain = KeychainStore(backend: fake, accessGroup: nil)
        let profile = UUID()

        let store = AutofillStore(fileURL: file, profile: profile, keychain: keychain)
        let address = AutofillAddress(name: "Ada Lovelace", street: "12 Secret Lane", city: "London", postalCode: "N1")
        store.save(address)
        store.save(AutofillCard(cardholder: "Ada", expMonth: 7, expYear: 2029, nickname: "Work"), number: "4242 4242 4242 4242")

        let raw = try Data(contentsOf: file)
        XCTAssertNil(raw.range(of: Data("Secret Lane".utf8)), "addresses must be encrypted at rest")
        XCTAssertNil(raw.range(of: Data("4242424242424242".utf8)), "card number must not be in the file")

        let reloaded = AutofillStore(fileURL: file, profile: profile, keychain: keychain)
        XCTAssertEqual(reloaded.addresses, [address])
        let card = try XCTUnwrap(reloaded.cards.first)
        XCTAssertEqual(card.masked, "•••• 4242")
        XCTAssertEqual(reloaded.number(for: card), "4242424242424242")
        XCTAssertTrue(reloaded.hasCard(number: "4242-4242-4242-4242"))
        XCTAssertTrue(reloaded.hasAddress(like: AutofillAddress(street: "12 secret lane", postalCode: "n1")))

        reloaded.delete(card)
        XCTAssertNil(reloaded.number(for: card))
        AutofillStore.deleteAll(profile: profile, keychain: keychain)
        XCTAssertTrue(fake.dataProtectionItems().isEmpty, "profile delete removes the file key")
        XCTAssertTrue(AutofillStore(fileURL: file, profile: profile, keychain: keychain).addresses.isEmpty)
    }
}
