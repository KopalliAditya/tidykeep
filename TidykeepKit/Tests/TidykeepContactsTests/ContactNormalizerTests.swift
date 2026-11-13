import Testing
import TidykeepContacts

@Suite struct ContactNormalizerTests {
    @Test func formattingDoesNotMatter() {
        let forms = ["(415) 555-0123", "415.555.0123", "415 555 0123", "4155550123", " 415-555-0123 "]
        #expect(Set(forms.map(ContactNormalizer.phoneKey)) == ["4155550123"])
    }

    @Test func countryCodeAndNationalFormMatch() {
        #expect(ContactNormalizer.phoneKey("+1 415 555 0123") == "4155550123")
        #expect(ContactNormalizer.phoneKey("1 (415) 555-0123") == "4155550123")
        // A 10-digit national number abroad loses its leading 0 the same way.
        #expect(ContactNormalizer.phoneKey("+44 20 7946 0958") == ContactNormalizer.phoneKey("020 7946 0958"))
    }

    @Test func doubleZeroPrefixIsInternational() {
        #expect(ContactNormalizer.phoneKey("0044 20 7946 0958") == ContactNormalizer.phoneKey("+44 20 7946 0958"))
        #expect(ContactNormalizer.phoneKey("001 415 555 0123") == "4155550123")
        // Short international numbers keep every digit after the prefix.
        #expect(ContactNormalizer.phoneKey("0049 30 12345") == "493012345")
        #expect(ContactNormalizer.phoneKey("+49 30 12345") == "493012345")
    }

    @Test func shortCodesAreIgnored() {
        for code in ["911", "112", "72345", "*86", "#31#", "", "call me"] {
            #expect(ContactNormalizer.phoneKey(code) == nil, "\(code)")
        }
        #expect(ContactNormalizer.phoneKey("555-1234") == "5551234")
    }

    @Test func extensionsArePartOfTheKey() {
        // Two direct lines on one switchboard are two phones.
        #expect(ContactNormalizer.phoneKey("+1 415 555 0123 ext. 12") == "4155550123X12")
        #expect(ContactNormalizer.phoneKey("415-555-0123 x12") == "4155550123X12")
        #expect(ContactNormalizer.phoneKey("(415) 555 0123 Extension 12") == "4155550123X12")
        #expect(ContactNormalizer.phoneKey("415 555 0123 ext 13") != ContactNormalizer.phoneKey("415 555 0123 ext 12"))
        #expect(ContactNormalizer.phoneKey("415 555 0123") != ContactNormalizer.phoneKey("415 555 0123 x12"))
        #expect(ContactNormalizer.phoneKey("415 555 0123,,4") == "4155550123,,4")
    }

    @Test func widthIsIgnored() {
        #expect(ContactNormalizer.phoneKey("４１５５５５０１２３") == "4155550123")
        #expect(ContactNormalizer.phoneKey("+44 (0)20 7946 0958") == ContactNormalizer.phoneKey("+44 20 7946 0958"))
    }

    @Test func sameNumberIgnoresOnlyFormattingAndHowTheCountryIsWritten() {
        #expect(ContactNormalizer.samePhoneNumber("+1 (415) 555-0123", "415.555.0123"))
        #expect(ContactNormalizer.samePhoneNumber("001 415 555 0123", "+1 415 555 0123"))
        #expect(ContactNormalizer.samePhoneNumber("415 555 0123 ext. 12", "(415) 555-0123 x12"))
    }

    @Test func numbersThatDialDifferentPhonesAreNotTheSame() {
        // Each pair was one number to the old loose key, so a merge deleted the second.
        let pairs = [
            ("415 555 0123 x12", "415 555 0123 x13"),
            ("415 555 0123", "415 555 0123 x12"),
            ("415 555 0123,,4", "415 555 0123,,5"),
            ("1-800-FLOWERS", "1-800-CONTACTS"),
            ("*86", "#86"),
            ("911", "912"),
            ("+91 92512 34567", "+1 925 123 4567"),
        ]
        for (a, b) in pairs {
            #expect(!ContactNormalizer.samePhoneNumber(a, b), "\(a) / \(b)")
        }
        #expect(ContactNormalizer.samePhoneNumber("*86", "*86"))
    }

    @Test func emailsIgnoreCaseAndSpaces() {
        #expect(ContactNormalizer.emailKey("  Aditya@Example.COM\n") == "aditya@example.com")
        #expect(ContactNormalizer.emailKey("mailto:a@b.co") == "a@b.co")
        #expect(ContactNormalizer.emailKey("not an email") == nil)
        #expect(ContactNormalizer.emailKey("@example.com") == nil)
        #expect(ContactNormalizer.emailKey("   ") == nil)
    }

    @Test func namesFoldAccentsCaseAndWidth() {
        let plain = ContactNormalizer.nameKey(card("1", given: "Jose", family: "Nunez"))
        #expect(plain == "jose nunez")
        #expect(ContactNormalizer.nameKey(card("2", given: "José", family: "Núñez")) == plain)
        #expect(ContactNormalizer.nameKey(card("3", given: "JOSE", family: "nunez")) == plain)
        #expect(ContactNormalizer.nameKey(card("4", given: "Ｊｏｓｅ", family: "Ｎｕｎｅｚ")) == plain)
    }

    @Test func nameOrderAndSpacesDoNotMatter() {
        let key = ContactNormalizer.nameKey(card("1", given: "Aditya", family: "Kopalli"))
        #expect(ContactNormalizer.nameKey(card("2", given: "Kopalli", family: "Aditya")) == key)
        #expect(ContactNormalizer.nameKey(card("3", given: "  Aditya   Kopalli ")) == key)
        #expect(ContactNormalizer.nameKey(card("4", given: " Aditya", family: "Kopalli  ")) == key)
        // A middle name is part of the name.
        #expect(ContactNormalizer.nameKey(card("5", given: "Aditya", middle: "K", family: "Kopalli")) != key)
    }

    @Test func punctuationInNames() {
        #expect(ContactNormalizer.nameKey(card("1", given: "Sean", family: "O'Brien"))
            == ContactNormalizer.nameKey(card("2", given: "Sean", family: "OBrien")))
        #expect(ContactNormalizer.nameKey(card("3", given: "Ann", family: "Smith-Jones"))
            == ContactNormalizer.nameKey(card("4", given: "Ann", family: "Smith Jones")))
    }

    @Test func singleWordNamesNeverKey() {
        #expect(ContactNormalizer.nameKey(card("1", given: "Mom")) == nil)
        #expect(ContactNormalizer.nameKey(card("2", family: "Kopalli")) == nil)
        // A person name, even a one-word one, wins over the organization.
        #expect(ContactNormalizer.nameKey(card("3", given: "Mom", org: "Acme")) == nil)
        #expect(ContactNormalizer.nameKey(card("4")) == nil)
    }

    @Test func organizationOnlyCardsKeyOnTheOrganization() {
        #expect(ContactNormalizer.nameKey(card("1", org: "Acme  Plumbing")) == "org:acme plumbing")
        #expect(ContactNormalizer.nameKey(card("2", org: "ACME plumbing")) == "org:acme plumbing")
        #expect(ContactNormalizer.nameKey(card("3", org: "Apple")) == "org:apple")
        // An organization never collides with a person of the same words.
        #expect(ContactNormalizer.nameKey(card("4", given: "Acme", family: "Plumbing")) != "org:acme plumbing")
    }

    @Test func departmentsOfOneOrganizationKeyApart() {
        let pharmacy = ContactNormalizer.nameKey(card("1", org: "Kaiser", department: "Pharmacy"))
        let nurse = ContactNormalizer.nameKey(card("2", org: "Kaiser", department: "Advice Nurse"))
        #expect(pharmacy != nurse)
        #expect(pharmacy == ContactNormalizer.nameKey(card("3", org: "KAISER", department: "pharmacy")))
        #expect(pharmacy != ContactNormalizer.nameKey(card("4", org: "Kaiser")))
    }

    @Test func theSuffixIsPartOfTheName() {
        let senior = ContactNormalizer.nameKey(card("1", given: "John", family: "Smith", suffix: "Sr."))
        let junior = ContactNormalizer.nameKey(card("2", given: "John", family: "Smith", suffix: "Jr."))
        #expect(senior != junior)
        #expect(senior == ContactNormalizer.nameKey(card("3", given: "john", family: "smith", suffix: "SR")))
        #expect(senior != ContactNormalizer.nameKey(card("4", given: "John", family: "Smith")))
    }
}
