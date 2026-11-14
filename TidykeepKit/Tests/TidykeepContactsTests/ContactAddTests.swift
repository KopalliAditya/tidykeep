import Foundation
import Testing
import TidykeepContacts

@Suite struct ContactAddTests {
    @Test func addSavesANewCardInTheBooksAccount() async throws {
        let store = InMemoryContactStore(cards: [card("a", given: "Dana", family: "Ray")])
        var sample = card("ignored", in: "elsewhere", isMe: true, given: "Jordan", family: "Rivera",
                          phones: ["+1 415 555 0134"], hasImage: true)
        sample.containerName = "Elsewhere"

        let id = try await store.add(sample)

        let cards = await store.cards()
        #expect(cards.count == 2)
        let added = try #require(cards.first { $0.id == id })
        #expect(id != "ignored")
        #expect(added.containerID == "phone")
        #expect(!added.isMe)
        #expect(!added.hasImage)
        #expect(added.displayName == "Jordan Rivera")
        #expect(added.phones.map(\.value) == ["+1 415 555 0134"])
    }

    @Test func addingTwiceMakesTwoCards() async throws {
        let store = InMemoryContactStore()
        let first = try await store.add(card("x", given: "Jordan", family: "Rivera"))
        let second = try await store.add(card("x", given: "Jordan", family: "Rivera"))
        #expect(first != second)
        #expect(await store.cards().count == 2)
    }

    @Test func addNeedsAccess() async {
        let store = InMemoryContactStore(access: .denied)
        await #expect(throws: ContactStoreError.notAuthorized) {
            _ = try await store.add(card("x", given: "Jordan"))
        }
        #expect(await store.cards().isEmpty)
    }
}
