/// Finds cards that look like the same person: the same name, phone number or email.
///
/// Cards that share a key are linked, and links chain (A–B by phone and B–C by email make one
/// group of three). Only links within one account make a group that can be merged. Links across
/// accounts are reported on their own, for information: merging those would move data between
/// accounts, and Contacts already offers linking for that.
///
/// A shared phone number or email is weaker evidence than a name: families share a landline and
/// couples an inbox. So a number or email never links two cards named as different people
/// ("Ann Lee" and "Ben Lee", see `ContactNormalizer.namesDiffer`), and a chain of links never
/// puts two such cards in one group.
public enum DuplicateContactFinder {
    /// A phone number or email on this many cards or more is a switchboard or a shared inbox,
    /// not a person, so it links nothing. Cards that are really one person still meet by name.
    public static let sharedValueLimit = 3

    public static func find(_ cards: [ContactCard]) -> (mergeable: [ContactDuplicateGroup], crossAccount: [ContactDuplicateGroup]) {
        // A card listed twice would link to itself.
        var seen = Set<String>()
        let cards = cards.filter { seen.insert($0.id).inserted }
        let names = cards.map(ContactNormalizer.PersonName.init)

        func link(_ links: inout UnionFind, _ a: Int, _ b: Int) {
            guard links.root(a) != links.root(b) else { return }
            let others = links.members(of: b)
            let apart = links.members(of: a).contains { x in
                others.contains { y in names[x].differs(from: names[y]) }
            }
            if !apart { links.link(a, b) }
        }

        // Names first, then phones, then emails, each in a fixed order: when two links can't
        // both be made, the stronger one wins, and the same one on every scan.
        let buckets = keyBuckets(cards)
        var sameAccount = UnionFind(count: cards.count)
        var anyAccount = UnionFind(count: cards.count)
        for bucket in buckets {
            for i in bucket.members.dropFirst() { link(&anyAccount, bucket.members[0], i) }
            let byAccount = Dictionary(grouping: bucket.members) { cards[$0].containerID }
            for account in byAccount.keys.sorted() {
                let members = byAccount[account] ?? []
                for i in members.dropFirst() { link(&sameAccount, members[0], i) }
            }
        }

        let mergeable = groups(&sameAccount, cards: cards, buckets: buckets, crossAccount: false)
        let crossAccount = groups(&anyAccount, cards: cards, buckets: buckets, crossAccount: true)
        return (mergeable, crossAccount)
    }

    /// The card a merge keeps by default: My Card, else the card with the most details (keeping
    /// it changes the least), else the smallest ID so the choice is the same on every scan.
    public static func keeper(among cards: [ContactCard]) -> ContactCard? {
        if let me = cards.first(where: \.isMe) { return me }
        return cards.max { a, b in
            a.detailCount != b.detailCount ? a.detailCount < b.detailCount : a.id > b.id
        }
    }

    /// Cards (by index, ascending) that share one key.
    struct Bucket {
        let reason: MatchReason
        let members: [Int]
    }

    /// Every bucket of two or more cards, names first, then phones, then emails, each sorted
    /// by members.
    static func keyBuckets(_ cards: [ContactCard]) -> [Bucket] {
        var names: [String: [Int]] = [:]
        var phones: [String: [(card: Int, country: String?)]] = [:]
        var emails: [String: [Int]] = [:]
        for (i, card) in cards.enumerated() {
            if let key = ContactNormalizer.nameKey(card) { names[key, default: []].append(i) }
            for phone in card.phones {
                let number = PhoneNumber(phone.value)
                if let key = number.matchKey { phones[key, default: []].append((i, number.countryCode)) }
            }
            for email in card.emails {
                if let key = ContactNormalizer.emailKey(email.value) { emails[key, default: []].append(i) }
            }
        }
        // Numbers that agree on their last digits but were written with different country
        // codes are different numbers. One written without a code could be either, so it then
        // matches neither.
        var phoneSets: [[Int]] = []
        for entries in phones.values {
            let codes = Set(entries.compactMap(\.country))
            guard codes.count > 1 else {
                phoneSets.append(entries.map(\.card))
                continue
            }
            for code in codes { phoneSets.append(entries.filter { $0.country == code }.map(\.card)) }
            phoneSets.append(entries.filter { $0.country == nil }.map(\.card))
        }
        func bucketed(_ sets: some Sequence<[Int]>, _ reason: MatchReason, limit: Int) -> [Bucket] {
            // A card that lists one value twice still counts once.
            sets.map { Array(Set($0)).sorted() }
                .filter { $0.count >= 2 && $0.count < limit }
                .sorted { $0.lexicographicallyPrecedes($1) }
                .map { Bucket(reason: reason, members: $0) }
        }
        return bucketed(names.values, .sameName, limit: .max)
            + bucketed(phoneSets, .samePhone, limit: sharedValueLimit)
            + bucketed(emails.values, .sameEmail, limit: sharedValueLimit)
    }

    private static func groups(
        _ links: inout UnionFind, cards: [ContactCard], buckets: [Bucket], crossAccount: Bool
    ) -> [ContactDuplicateGroup] {
        // A reason belongs to a group when two of its cards share that key.
        var reasons: [Int: Set<MatchReason>] = [:]
        for bucket in buckets {
            var perRoot: [Int: Int] = [:]
            for i in bucket.members { perRoot[links.root(i), default: 0] += 1 }
            for (root, count) in perRoot where count >= 2 {
                reasons[root, default: []].insert(bucket.reason)
            }
        }
        return links.groups().compactMap { members in
            let groupCards = members.map { cards[$0] }
            // Every link that stays inside one account is already a mergeable group.
            if crossAccount, Set(groupCards.map(\.containerID)).count < 2 { return nil }
            guard let keeper = keeper(among: groupCards) else { return nil }
            let ids = [keeper.id] + groupCards.map(\.id).filter { $0 != keeper.id }
            return ContactDuplicateGroup(
                cardIDs: ids,
                reasons: reasons[links.root(members[0])] ?? [],
                keeperID: keeper.id,
                isCrossAccount: crossAccount
            )
        }
    }
}
