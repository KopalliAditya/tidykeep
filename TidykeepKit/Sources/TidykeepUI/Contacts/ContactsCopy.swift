import Foundation
import TidykeepContacts

extension Copy {
    /// Duplicate Contacts: the pre-permission screen, the list, the merge screen, its notices
    /// and the Contacts part of Rules.
    enum Contacts {
        // MARK: Before access

        static let introTitle = "Find duplicate contacts"
        static let introDetail = "\(appName) looks for cards that belong to the same person, so you can merge them into one."
        static let introRows: [(symbol: String, text: String)] = [
            ("person.text.rectangle", "Reads names, phone numbers and emails, and compares them on this iPhone."),
            ("eye", "Shows each merge first. Nothing changes until you confirm it."),
            ("externaldrive.badge.checkmark", "Saves a vCard backup on this iPhone before every merge, so you can undo it."),
            ("iphone", "Your contacts never leave this iPhone."),
        ]
        static let `continue` = "Continue"

        static let accessOff = "Contacts access is off"
        static let accessOffDetail = "To find duplicate cards, open the Settings app, tap Apps, then \(appName), then Contacts, and choose Full Access. Photos and files still work."

        // MARK: List

        static let checking = "Checking your contacts…"
        static func checked(_ n: Int) -> String { "Checked \(count(n, "card", "cards")) on this iPhone" }
        static let limited = "Checking only the contacts you shared with \(appName)."
        static let scanFailed = "Couldn't read your contacts. Nothing changed."
        static let emptyDetail = "No cards look like the same person."

        static func section(_ reason: MatchReason) -> String {
            switch reason {
            case .sameName: "Same name"
            case .samePhone: "Same phone number"
            case .sameEmail: "Same email"
            }
        }

        /// "Same phone · Same name", strongest first.
        static func reasons(_ reasons: Set<MatchReason>) -> String {
            ordered(reasons).map(short).joined(separator: " · ")
        }

        /// "Same phone number and same name.", for the reason card.
        static func why(_ reasons: Set<MatchReason>) -> String {
            let words = ordered(reasons).map { section($0).lowercased() }
            guard let first = words.first else { return "These cards look like the same person." }
            let list = words.count == 1 ? first : words.dropLast().joined(separator: ", ") + " and " + (words.last ?? "")
            return list.prefix(1).uppercased() + list.dropFirst() + "."
        }

        private static func short(_ reason: MatchReason) -> String {
            switch reason {
            case .sameName: "Same name"
            case .samePhone: "Same phone"
            case .sameEmail: "Same email"
            }
        }

        private static func ordered(_ reasons: Set<MatchReason>) -> [MatchReason] {
            [MatchReason.samePhone, .sameEmail, .sameName].filter(reasons.contains)
        }

        static func accounts(_ names: [String]) -> String { names.joined(separator: " · ") }

        /// VoiceOver label for a list row: "Jordan Rivera, 2 cards, Same phone · Same name, iCloud".
        static func rowLabel(_ name: String, cards n: Int, reasons: Set<MatchReason>, accounts: [String]) -> String {
            ([name, Copy.cards(n), Self.reasons(reasons)] + (accounts.isEmpty ? [] : [Self.accounts(accounts)]))
                .joined(separator: ", ")
        }

        static let otherAccounts = "In different accounts"
        static let otherAccountsFooter = "These cards are in different accounts, so \(appName) doesn't merge them: that would move details from one account to another. To see them as one person, open the card in Contacts and link them there."
        static let notMergeable = "Not merged"

        static let keepBoth = "Keep both"
        static let keepBothHint = "Stops suggesting these cards."

        // MARK: Names and fields

        static let unnamed = "No name"

        /// A card's name as Contacts shows it, or "No name".
        static func name(_ card: ContactCard?) -> String {
            let name = card?.displayName ?? ""
            return name.isEmpty ? unnamed : name
        }

        /// Up to two letters for the monogram.
        static func initials(_ card: ContactCard?) -> String {
            guard let card else { return "" }
            let parts = [card.givenName, card.familyName].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let source = parts.isEmpty ? [card.displayName] : parts
            return String(source.compactMap { $0.trimmingCharacters(in: .whitespaces).first }.prefix(2)).uppercased()
        }

        static func cardNumber(_ index: Int) -> String { "Card \(index + 1)" }
        static func fromCard(_ index: Int) -> String { "From card \(index + 1)" }
        static func details(_ n: Int) -> String { count(n, "detail", "details") }
        static let hasPhoto = "Has a photo"
        static let noDetails = "Only a name"

        /// A raw Contacts label ("_$!<Mobile>!$_") in words ("mobile"). Labels the user typed
        /// stay as typed.
        static func label(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            guard raw.hasPrefix("_$!<"), raw.hasSuffix(">!$_") else { return raw }
            let key = String(raw.dropFirst(4).dropLast(4))
            if let known = knownLabels[key] { return known }
            // CamelCase to words: "HomePage" → "home page".
            var words = ""
            for ch in key {
                if ch.isUppercase, !words.isEmpty { words.append(" ") }
                words.append(ch)
            }
            return words.lowercased()
        }

        private static let knownLabels: [String: String] = [
            "Mobile": "mobile", "iPhone": "iPhone", "Main": "main", "Home": "home", "Work": "work",
            "School": "school", "Other": "other", "HomeFAX": "home fax", "WorkFAX": "work fax",
            "OtherFAX": "other fax", "Pager": "pager", "HomePage": "homepage", "Anniversary": "anniversary",
            "AppleWatch": "Apple Watch",
        ]

        /// An address on one line: "1 Main St, Livermore, CA 94550".
        static func address(_ a: LabeledPostal) -> String {
            let street = a.street.split(whereSeparator: \.isNewline).map(String.init)
            let cityLine = [a.city, [a.state, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")]
                .filter { !$0.isEmpty }.joined(separator: ", ")
            return (street + [a.subLocality, cityLine, a.country])
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }

        /// "March 4, 1994", or "December 25" without a year.
        static func date(_ components: DateComponents) -> String {
            var c = components
            c.calendar = Calendar(identifier: .gregorian)
            let hasYear = components.year != nil
            if !hasYear { c.year = 2000 }
            guard let date = c.date else { return "" }
            return hasYear
                ? date.formatted(.dateTime.month(.wide).day().year())
                : date.formatted(.dateTime.month(.wide).day())
        }

        static let phone = "phone"
        static let email = "email"
        static let address = "address"
        static let birthday = "birthday"
        static let web = "web"
        static let company = "company"
        static let nickname = "nickname"
        static let dateLabel = "date"
        static let related = "related"
        static let profile = "profile"
        static let chat = "chat"

        // MARK: Merge screen

        static let mergedCard = "Merged card"
        static func added(_ n: Int) -> String {
            n == 0
                ? "Nothing new to add. The other cards hold the same details."
                : "Adds \(count(n, "detail", "details")) from the other cards."
        }
        static let choose = "Choose"
        static let chooseFooter = "The merged card can have one name and one photo."
        static let nameChoice = "Name"
        static let photoChoice = "Photo"
        static func photoFrom(_ index: Int) -> String { "Card \(index + 1)'s photo" }
        static let noPhoto = "No photo"
        static let photo = "photo"

        static let cardsBeingMerged = "Cards being merged"
        static let keeperFooter = "The card that stays keeps its notes and its links from other apps. The others are removed after their details are copied over."
        static let stays = "Stays"
        static let goes = "Removed"
        static let keepThisCard = "Keep this card"
        static let stayHint = "Makes this the card that stays."
        static func staysAnnouncement(_ index: Int) -> String { "Card \(index + 1) stays." }

        /// "Notes can't be checked. If card 2 has notes, copy them first."
        static func notesCaveat(_ removed: [Int]) -> String {
            "Notes can't be checked. If \(cardList(removed)) \(removed.count == 1 ? "has" : "have") notes, copy them first."
        }

        static func mergeButton(_ n: Int) -> String { "Merge \(cards(n))" }
        static let mergeHint = "Asks first. A backup is saved before anything changes."

        static func confirmTitle(_ removed: [Int]) -> String {
            "Notes on \(cardList(removed)) can't be checked"
        }
        static func confirmMessage(_ removed: [Int]) -> String {
            removed.count == 1
                ? "If it has notes, they'll be lost. Everything else is saved in a backup first."
                : "If they have notes, they'll be lost. Everything else is saved in a backup first."
        }
        static let mergeAnyway = "Merge anyway"

        /// "card 2", "cards 2 and 3".
        private static func cardList(_ indexes: [Int]) -> String {
            let numbers = indexes.map { "\($0 + 1)" }
            guard numbers.count > 1, let last = numbers.last else { return "card \(numbers.first ?? "")" }
            return "cards " + numbers.dropLast().joined(separator: ", ") + " and " + last
        }

        static func keptSafe(_ n: Int) -> String {
            n == 2
                ? "A vCard backup of both cards is saved on this iPhone first."
                : "A vCard backup of all \(n) cards is saved on this iPhone first."
        }
        static func undoReason(_ n: Int) -> String {
            "Undo from the notice or in History. It puts the card that stays back as it was and restores the other \(n == 2 ? "card" : "\(n - 1) cards") as new."
        }

        static let gone = "These cards were merged or changed since the check."

        // MARK: Problems

        static func problem(_ problem: ContactsModel.MergeProblem) -> String {
            switch problem {
            case .changed: "One of these cards changed since the check. Nothing was merged."
            case .crossAccount: "These cards are in different accounts, so they can't be merged. Nothing changed."
            case .myCard: "My Card can only be the card that stays. Nothing was merged."
            case .notAuthorized: "Contacts access is off. Nothing was merged."
            case .backupFailed: "Couldn't save the backup, so nothing was merged."
            case .other: "Couldn't merge. The cards are unchanged."
            }
        }

        // MARK: Notices

        /// "Merged 2 cards into Jordan Rivera."
        static func merged(_ n: Int, into name: String) -> String { "Merged \(cards(n)) into \(name)." }
        static func undone(_ name: String, cards n: Int) -> String { "Undone. \(name) is back to \(cards(n))." }
        static let keptBoth = "Kept both cards. They won't be suggested again."
        static let suggestedAgain = "Cards you kept apart are back in the list."
        static func keeperEdited(_ name: String) -> String {
            "\(name) was edited after the merge. Undo would replace those edits with the details from before."
        }
        static let undoAnyway = "Undo anyway"
        static func keeperDeleted(_ name: String) -> String {
            "\(name) was deleted after the merge. Undo can bring back all the original cards as new cards."
        }
        static let restoreAnyway = "Restore anyway"
        static func keeperNotShared(_ name: String) -> String {
            "\(name) isn't shared with \(appName) now. Share it again in Settings, then undo. Nothing changed."
        }
        static let alreadyBack = "The original cards are already there. Nothing changed."
        static let backupGone = "The backup for this merge is gone, so it can't be undone. Nothing changed."
        static let undoNeedsAccess = "Contacts access is off, so the merge can't be undone. Nothing changed."
        static let undoFailed = "Couldn't undo. Nothing changed."
        static let backupsDeleted = "Contact backups deleted."

        // MARK: Rules

        static let rulesTitle = "Contacts"
        static let accessTitle = "Access"
        static func accessValue(_ access: ContactsModel.Access, limited: Bool) -> String {
            switch access {
            case .notDetermined: "Not asked yet"
            case .denied: "Off"
            case .allowed: limited ? "Some contacts" : "Full access"
            }
        }
        static let myCard = "\(appName) can't tell which card is yours: iPhone doesn't share that with apps. When you merge your own card, check that it's the one that stays."
        static let backups = "Saved backups"
        static func backupCount(_ n: Int) -> String { n == 0 ? "None" : count(n, "backup", "backups") }
        static let deleteBackups = "Delete backups"
        static let deleteBackupsTitle = "Delete contact backups?"
        static let deleteBackupsMessage = "Merges made before can't be undone after this. Your contacts aren't changed."
        static let keptApartTitle = "Kept apart"
        static func groups(_ n: Int) -> String { count(n, "group", "groups") }
        static let suggestAgain = "Suggest them again"
        static let rulesFooter = "Cards are merged only within one account. A phone number shared by 3 or more cards, like an office line, doesn't count as a match."
    }
}
