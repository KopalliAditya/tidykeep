import Foundation
import SwiftUI
import Testing
import TidykeepContacts
import TidykeepCore
import TidykeepFolderSource
@testable import TidykeepUI
import TidykeepVision

/// The contacts screens, drawn from a made-up address book in memory. The real address book
/// is never opened.
///
///     TK_RENDER_DIR=/tmp/renders bash scripts/test.sh --filter ContactsRenders
@MainActor @Suite(.serialized) struct ContactsRenders {
    // MARK: Screens

    @Test func prePermission() async {
        let state = await Self.state(InMemoryContactStore(cards: Self.book, access: .notDetermined))
        await RenderHarness.render(DuplicateContactsView(), named: "contacts-intro", state: state)
    }

    @Test func list() async {
        let state = await Self.state(InMemoryContactStore(cards: Self.book))
        #expect(state.contacts.duplicateGroupCount == 3)
        #expect(state.contacts.crossAccountGroups.count == 1)
        await RenderHarness.render(DuplicateContactsView(), named: "contacts-list", state: state, height: 1_100)
        await RenderHarness.render(
            DuplicateContactsView().environment(\.dynamicTypeSize, .accessibility2),
            named: "contacts-list-ax", state: state)
    }

    @Test func merge() async throws {
        let state = await Self.state(InMemoryContactStore(cards: Self.book))
        let priya = try #require(state.contacts.groups.first { state.contacts.name(of: $0).hasPrefix("Priya") })
        await RenderHarness.render(ContactMergeView(groupID: priya.id), named: "contacts-merge", state: state, height: 1_900)
        let jordan = try #require(state.contacts.groups.first { state.contacts.name(of: $0) == "Jordan Rivera" })
        await RenderHarness.render(ContactMergeView(groupID: jordan.id), named: "contacts-merge-jordan", state: state)
        await RenderHarness.render(
            ContactMergeView(groupID: jordan.id).environment(\.dynamicTypeSize, .accessibility2),
            named: "contacts-merge-ax", state: state, height: 2_200)
    }

    @Test func denied() async {
        let state = await Self.state(InMemoryContactStore(cards: Self.book, access: .denied))
        await RenderHarness.render(DuplicateContactsView(), named: "contacts-denied", state: state)
    }

    @Test func restricted() async {
        let state = await Self.state(InMemoryContactStore(cards: Self.book, access: .restricted))
        await RenderHarness.render(DuplicateContactsView(), named: "contacts-restricted", state: state)
    }

    @Test func limited() async {
        let state = await Self.state(InMemoryContactStore(cards: Self.book, access: .limited))
        await RenderHarness.render(DuplicateContactsView(), named: "contacts-limited", state: state, height: 1_100)
        let none = await Self.state(InMemoryContactStore(cards: [Self.book[0], Self.book[7]], access: .limited))
        await RenderHarness.render(DuplicateContactsView(), named: "contacts-limited-empty", state: none)
    }

    @Test func failed() async {
        let store = FlakyContactStore(InMemoryContactStore(cards: Self.book))
        store.failsToRead = true
        let state = await Self.state(store)
        #expect(state.contacts.scanFailed)
        await RenderHarness.render(DuplicateContactsView(), named: "contacts-failed", state: state)
    }

    @Test func empty() async {
        let state = await Self.state(InMemoryContactStore(cards: [Self.book[0], Self.book[7]]))
        #expect(state.contacts.duplicateGroupCount == 0)
        await RenderHarness.render(DuplicateContactsView(), named: "contacts-empty", state: state)
    }

    @Test func rules() async throws {
        let state = await Self.state(InMemoryContactStore(cards: Self.book))
        let jordan = try #require(state.contacts.groups.first { state.contacts.name(of: $0) == "Jordan Rivera" })
        await state.contacts.merge(jordan.id, keeperID: jordan.keeperID, choices: MergeChoices(nameFrom: jordan.keeperID))
        if let sam = state.contacts.groups.first(where: { state.contacts.name(of: $0).hasPrefix("Sam") }) {
            state.contacts.keepApart(sam.id)
        }
        await RenderHarness.render(Self.rulesForm, named: "contacts-rules", state: state)

        let undecided = await Self.state(InMemoryContactStore(access: .notDetermined))
        await RenderHarness.render(Self.rulesForm, named: "contacts-rules-notasked", state: undecided)
    }

    private static var rulesForm: some View {
        Form { ContactsRulesSection() }
            .formStyle(.grouped)
            .navigationTitle(Copy.Tabs.rules)
    }

    // MARK: Data

    /// An app state with no photos and the given address book, checked.
    static func state(_ store: any ContactStoring) async -> AppState {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "onboarded")
        let state = AppState(
            photoSource: FolderPhotoSource(folder: temporaryDirectory("contacts-render-photos-\(UUID().uuidString)")),
            analyzer: VisionFrameAnalyzer(),
            directory: temporaryDirectory("contacts-render-data-\(UUID().uuidString)"),
            defaults: defaults,
            findsCopies: false,
            contactStore: store)
        await state.contacts.start()
        return state
    }

    private static func phone(_ value: String, _ label: String = "_$!<Mobile>!$_") -> LabeledValue {
        LabeledValue(label: label, value: value)
    }

    /// Three mergeable groups (same phone, same email, three cards), one pair in different
    /// accounts, and people with no duplicates.
    static let book: [ContactCard] = [
        ContactCard(id: "ana", containerID: "icloud", containerName: "iCloud", givenName: "Ana", familyName: "Lima",
                    phones: [phone("+1 510 555 0172")]),
        ContactCard(id: "jordan-1", containerID: "icloud", containerName: "iCloud", givenName: "Jordan", familyName: "Rivera",
                    phones: [phone("+1 415 555 0134")]),
        ContactCard(id: "jordan-2", containerID: "icloud", containerName: "iCloud", givenName: "Jordan", familyName: "Rivera",
                    organization: "Bayside Clinic", jobTitle: "Nurse",
                    phones: [phone("(415) 555-0134", "_$!<Work>!$_")],
                    emails: [LabeledValue(label: "_$!<Work>!$_", value: "jordan@bayside.example")]),
        ContactCard(id: "priya-1", containerID: "icloud", containerName: "iCloud", givenName: "Priya", familyName: "Natarajan",
                    phones: [phone("+1 925 555 0148")],
                    emails: [LabeledValue(label: "_$!<Home>!$_", value: "priya.n@mail.example")],
                    birthday: DateComponents(month: 3, day: 4), hasImage: true),
        ContactCard(id: "priya-2", containerID: "icloud", containerName: "iCloud", givenName: "Priya", familyName: "N",
                    organization: "Livermore Library",
                    emails: [LabeledValue(label: "_$!<Home>!$_", value: "Priya.N@mail.example")],
                    postalAddresses: [LabeledPostal(label: "_$!<Home>!$_", street: "212 Oak Street", city: "Livermore", state: "CA", postalCode: "94550")],
                    hasImage: true),
        ContactCard(id: "sam-1", containerID: "icloud", containerName: "iCloud", givenName: "Sam", familyName: "Okafor",
                    phones: [phone("+1 650 555 0190")]),
        ContactCard(id: "sam-2", containerID: "icloud", containerName: "iCloud", givenName: "Sam", familyName: "Okafor",
                    emails: [LabeledValue(label: "_$!<Other>!$_", value: "sam.okafor@mail.example")]),
        ContactCard(id: "wei", containerID: "icloud", containerName: "iCloud", givenName: "Wei", familyName: "Zhang",
                    emails: [LabeledValue(value: "wei@mail.example")]),
        ContactCard(id: "sam-3", containerID: "icloud", containerName: "iCloud", givenName: "Sam", familyName: "Okafor",
                    nickname: "Sammy", phones: [phone("650-555-0190", "_$!<Home>!$_")]),
        ContactCard(id: "maya-1", containerID: "icloud", containerName: "iCloud", givenName: "Maya", familyName: "Cohen",
                    phones: [phone("+1 408 555 0111")]),
        ContactCard(id: "maya-2", containerID: "gmail", containerName: "Gmail", givenName: "Maya", familyName: "Cohen",
                    phones: [phone("408 555 0111")]),
    ]
}
