import Foundation

/// Works out a merge: what the keeper looks like afterwards and where each value came from.
///
/// Multi-value fields (phones, emails, addresses, web addresses, dates, relations, social
/// profiles, instant message addresses) are the union of all cards: the keeper's own values
/// first, exactly as they are, then each other card's values that aren't already there. Two
/// values count as one only when they certainly are one (see `samePhoneNumber`); when in doubt
/// both stay, because a value wrongly called a repeat is deleted with its card. When two values
/// are one, the first wins, so the keeper's label stays.
///
/// Fields that hold one value come from the keeper, and when the keeper's is blank, from the
/// first card that has one. The name and photo follow the user's choices. What a merge drops
/// on purpose is a second, different value of a one-value field: another name, nickname,
/// birthday or job than the one kept, and how a dropped name is said. The merge screen shows
/// every card, and the backup keeps them all.
public enum MergePlanner {
    /// The plan for merging `cards` into the card `keeperID`.
    ///
    /// Two safety rules hold whatever is passed in. My Card is the keeper if it is among the
    /// cards, so it is never removed. Cards in another account than the keeper's are left out,
    /// because merges stay within one account. An unknown `keeperID` falls back to the
    /// finder's default keeper. No cards at all (they were deleted or merged elsewhere since
    /// the scan) throws `cardNotFound` for `keeperID`.
    public static func plan(
        cards: [ContactCard], keeperID: String, choices: MergeChoices
    ) throws(ContactStoreError) -> MergePlan {
        guard let keeper = cards.first(where: \.isMe)
            ?? cards.first(where: { $0.id == keeperID })
            ?? DuplicateContactFinder.keeper(among: cards)
        else {
            throw .cardNotFound(id: keeperID)
        }
        var seen: Set = [keeper.id]
        let others = cards.filter {
            $0.containerID == keeper.containerID && !$0.isMe && seen.insert($0.id).inserted
        }
        let all = [keeper] + others
        var merged = keeper
        var sources: [String: String] = [:]

        func fill(_ field: ManagedField, _ key: String, from candidates: [ContactCard], when has: (ContactCard) -> Bool) {
            guard let card = candidates.first(where: has) else { return }
            merged.copy(field, from: card)
            sources[key] = card.id
        }

        // A chosen card without a person name (a company card, often the keeper) would leave
        // the merged card nameless, so the first card with a name stands in.
        let chosen = all.first { $0.id == choices.nameFrom } ?? keeper
        let nameCard = chosen.personName.isEmpty ? all.first { !$0.personName.isEmpty } ?? chosen : chosen
        merged.copy(.name, from: nameCard)
        if !nameCard.personName.isEmpty { sources[MergeField.name] = nameCard.id }
        // How a name is said belongs to that name: it comes from a card with the same name.
        let words = ContactNormalizer.nameWords(nameCard)
        merged.copy(.phoneticName, from: nameCard)
        fill(.phoneticName, MergeField.phoneticName, from: [nameCard] + all) {
            $0.hasPhoneticName && ContactNormalizer.nameWords($0) == words
        }

        fill(.previousFamilyName, MergeField.previousFamilyName, from: all) { !$0.previousFamilyName.isBlank }
        fill(.nickname, MergeField.nickname, from: all) { !$0.nickname.isBlank }
        planJob(all, into: &merged, sources: &sources)
        planBirthday(all, into: &merged, sources: &sources)
        fill(.nonGregorianBirthday, MergeField.nonGregorianBirthday, from: all) { $0.nonGregorianBirthday != nil }

        let photoCard = all.first { $0.id == choices.photoFrom && $0.hasImage } ?? all.first(where: \.hasImage)
        merged.hasImage = photoCard != nil
        if let photoCard { sources[MergeField.photo] = photoCard.id }

        merged.phones = union(all, \.phones, key: { $0.value.isBlank ? nil : PhoneNumber($0.value) },
                              same: { $0.isSame(as: $1) }, field: MergeField.phone, into: &sources)
        merged.emails = union(all, \.emails, key: emailDedupeKey, field: MergeField.email, into: &sources)
        merged.postalAddresses = union(all, \.postalAddresses, key: postalDedupeKey, field: MergeField.postalAddress, into: &sources)
        merged.urls = union(all, \.urls, key: urlDedupeKey, field: MergeField.url, into: &sources)
        merged.dates = union(all, \.dates, key: dateDedupeKey, field: MergeField.date, into: &sources)
        merged.relations = union(all, \.relations, key: relationDedupeKey, field: MergeField.relation, into: &sources)
        merged.socialProfiles = union(all, \.socialProfiles, key: socialDedupeKey, field: MergeField.socialProfile, into: &sources)
        merged.instantMessages = union(all, \.instantMessages, key: instantMessageDedupeKey, field: MergeField.instantMessage, into: &sources)

        return MergePlan(
            keeperID: keeper.id,
            removedIDs: others.map(\.id),
            keeperBefore: keeper,
            removedBefore: others,
            merged: merged,
            fieldSources: sources,
            addedFieldCount: sources.values.filter { $0 != keeper.id }.count,
            photoFromID: photoCard.flatMap { $0.id == keeper.id ? nil : $0.id }
        )
    }

    /// Organization, department, job title and how the organization is said describe one job,
    /// so they come from one card: the first with any of the first three. Its blanks are filled
    /// only from cards at the same organization. A title from another company, or from a card
    /// with no company, would describe a job nobody may have, so it isn't borrowed.
    private static func planJob(_ all: [ContactCard], into merged: inout ContactCard, sources: inout [String: String]) {
        guard let job = all.first(where: { !$0.organization.isBlank || !$0.jobTitle.isBlank || !$0.department.isBlank })
        else { return }
        let organization = ContactNormalizer.folded(job.organization)
        let colleagues = organization.isEmpty ? [] : all.filter { ContactNormalizer.folded($0.organization) == organization }
        let parts: [(ManagedField, String, KeyPath<ContactCard, String>)] = [
            (.organization, MergeField.organization, \.organization),
            (.department, MergeField.department, \.department),
            (.jobTitle, MergeField.jobTitle, \.jobTitle),
            (.phoneticOrganization, MergeField.phoneticOrganization, \.phoneticOrganization),
        ]
        for (field, key, value) in parts {
            let card = ([job] + colleagues).first { !$0[keyPath: value].isBlank } ?? job
            merged.copy(field, from: card)
            if !card[keyPath: value].isBlank { sources[key] = card.id }
        }
    }

    /// The first birthday, or the same day with its year when another card knows the year.
    private static func planBirthday(_ all: [ContactCard], into merged: inout ContactCard, sources: inout [String: String]) {
        guard let first = all.first(where: { $0.birthday != nil }), let day = first.birthday else { return }
        let card = day.year != nil ? first : all.first {
            $0.birthday?.year != nil && $0.birthday?.month == day.month && $0.birthday?.day == day.day
        } ?? first
        merged.birthday = card.birthday
        sources[MergeField.birthday] = card.id
    }

    /// The keeper's values untouched, then the others' new ones. A blank value (nil key) adds
    /// nothing.
    private static func union<Value, Key>(
        _ cards: [ContactCard], _ values: (ContactCard) -> [Value], key: (Value) -> Key?,
        same: (Key, Key) -> Bool, field: (Int) -> String, into sources: inout [String: String]
    ) -> [Value] {
        var out: [Value] = []
        var kept: [Key] = []
        for (n, card) in cards.enumerated() {
            for value in values(card) {
                let k = key(value)
                if n > 0 {
                    guard let k, !kept.contains(where: { same($0, k) }) else { continue }
                }
                if let k { kept.append(k) }
                sources[field(out.count)] = card.id
                out.append(value)
            }
        }
        return out
    }

    private static func union<Value>(
        _ cards: [ContactCard], _ values: (ContactCard) -> [Value], key: (Value) -> String?,
        field: (Int) -> String, into sources: inout [String: String]
    ) -> [Value] {
        union(cards, values, key: key, same: ==, field: field, into: &sources)
    }

    // Dedupe keys only ever drop formatting: case, spacing, punctuation. The phone rule lives
    // in `PhoneNumber.isSame`.

    static func emailDedupeKey(_ email: LabeledValue) -> String? {
        ContactNormalizer.emailKey(email.value)
            ?? blankless(email.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func postalDedupeKey(_ address: LabeledPostal) -> String? {
        address.isEmpty ? nil : address.parts.map(ContactNormalizer.folded).joined(separator: "|")
    }

    /// Case, a trailing slash, the scheme and "www." don't make a different site.
    static func urlDedupeKey(_ url: LabeledValue) -> String? {
        var text = url.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slashes = text.range(of: "//"), text[..<slashes.lowerBound].hasSuffix(":") {
            text = String(text[slashes.upperBound...])
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        while text.hasSuffix("/") { text.removeLast() }
        return blankless(text)
    }

    /// A date means what its label says, so the same day under two labels is two dates.
    static func dateDedupeKey(_ date: LabeledDate) -> String? {
        let d = date.date
        guard d.month != nil || d.day != nil || d.year != nil else { return nil }
        return [ContactCard.label(date.label) ?? "", d.year.map(String.init) ?? "",
                d.month.map(String.init) ?? "", d.day.map(String.init) ?? ""].joined(separator: "|")
    }

    /// "Sister: Ana" and "Mother: Ana" are two relations.
    static func relationDedupeKey(_ relation: LabeledValue) -> String? {
        let name = ContactNormalizer.folded(relation.value)
        return name.isEmpty ? nil : (ContactCard.label(relation.label) ?? "") + "|" + name
    }

    static func socialDedupeKey(_ profile: LabeledSocialProfile) -> String? {
        guard !profile.isEmpty else { return nil }
        return [profile.service, profile.username, profile.userIdentifier, profile.urlString]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
    }

    static func instantMessageDedupeKey(_ address: LabeledInstantMessage) -> String? {
        let name = address.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name.isEmpty ? nil : address.service.lowercased() + "|" + name
    }

    private static func blankless(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }
}

extension ContactCard {
    var hasPhoneticName: Bool {
        !(phoneticGivenName.isBlank && phoneticMiddleName.isBlank && phoneticFamilyName.isBlank)
    }
}
