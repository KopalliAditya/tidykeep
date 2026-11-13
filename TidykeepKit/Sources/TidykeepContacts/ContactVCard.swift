import Contacts
import Foundation

/// One card in a backup: what undo needs to re-create it as it was.
struct ContactBackupEntry: Sendable, Hashable {
    /// The card's identifier when it was backed up.
    var id: String
    var card: ContactCard
    var imageData: Data?
    /// A company card rather than a person's.
    var isOrganization: Bool = false
    /// The groups the card was in, so undo can put a re-created card back in them and take
    /// the keeper out of the ones the merge added it to.
    var groupIDs: [String] = []
}

/// The backup format: a plain vCard file any contacts app can import, with three additions.
///
/// - Each card carries its original identifier in an `X-TIDYKEEP-ID` line, so undo restores
///   exactly the removed cards and can tell the keeper's entry apart.
/// - Each card carries an `X-TIDYKEEP-RECORD` line: every field exactly, its type and its
///   groups, as base64 JSON. Undo re-creates cards from the record rather than from the
///   vCard text, because Apple's vCard reader loses some fields (how a company name is said,
///   parts of social profiles, birthdays in other calendars) and relabels others.
/// - Each photo is written as a `PHOTO` line by hand, because Apple's vCard writer leaves
///   photos out (its reader takes them in).
///
/// Other apps ignore `X-` lines. Only new contacts built in memory are written (see
/// `ContactCard.newContact`), so the writer never needs a note it can't read.
enum ContactVCard {
    static let idProperty = "X-TIDYKEEP-ID"
    static let recordProperty = "X-TIDYKEEP-RECORD"
    /// vCard lines are folded at 75 bytes.
    private static let lineLimit = 75

    /// What the record line holds.
    private struct Record: Codable {
        var card: ContactCard
        var isOrganization: Bool
        var groupIDs: [String]
    }

    /// One vCard file holding every entry, in order.
    static func data(_ entries: [ContactBackupEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var file = ""
        for entry in entries {
            let contact = entry.card.newContact(imageData: entry.imageData, isOrganization: entry.isOrganization)
            let single = try CNContactVCardSerialization.data(with: [contact])
            guard var text = String(data: single, encoding: .utf8),
                  let end = text.range(of: "END:VCARD", options: [.backwards, .caseInsensitive])
            else { throw ContactStoreError.unreadableBackup }
            var extra = ""
            if let image = entry.imageData, text.range(of: "\nPHOTO", options: .caseInsensitive) == nil {
                extra += folded("PHOTO;ENCODING=b" + imageType(image) + ":" + image.base64EncodedString())
            }
            extra += folded(idProperty + ":" + entry.id.filter { !$0.isNewline })
            let record = Record(card: entry.card, isOrganization: entry.isOrganization, groupIDs: entry.groupIDs)
            extra += folded(recordProperty + ":" + (try encoder.encode(record)).base64EncodedString())
            text.insert(contentsOf: extra, at: end.lowerBound)
            if !text.hasSuffix("\n") { text += "\r\n" }
            file += text
        }
        return Data(file.utf8)
    }

    /// The entries in a backup, by original identifier. Entries without one are skipped:
    /// they weren't written by this app, so nothing says which card they were. An entry
    /// without a record is read from its vCard text alone.
    static func entries(in data: Data) throws -> [String: ContactBackupEntry] {
        guard let text = String(data: data, encoding: .utf8) else { throw ContactStoreError.unreadableBackup }
        let unfolded = text
            .replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
        var result: [String: ContactBackupEntry] = [:]
        var block: [Substring] = []
        var inside = false
        for line in unfolded.split(whereSeparator: \.isNewline) {
            // Photo lines run to many kilobytes; only short lines can be markers.
            let marker = line.utf8.count < 32 ? line.trimmingCharacters(in: .whitespaces).uppercased() : ""
            if marker == "BEGIN:VCARD" {
                inside = true
                block = []
            }
            guard inside else { continue }
            block.append(line)
            guard marker == "END:VCARD" else { continue }
            inside = false
            guard let id = block.lazy.compactMap({ value(of: idProperty, in: $0) }).first else { continue }
            let vCard = Data(block.joined(separator: "\r\n").utf8)
            guard let contact = (try? CNContactVCardSerialization.contacts(with: vCard))?.first else {
                throw ContactStoreError.unreadableBackup
            }
            let image = contact.isKeyAvailable(CNContactImageDataKey) ? contact.imageData : nil
            if let line = block.lazy.compactMap({ value(of: recordProperty, in: $0) }).first {
                guard let json = Data(base64Encoded: line),
                      let record = try? JSONDecoder().decode(Record.self, from: json)
                else { throw ContactStoreError.unreadableBackup }
                result[id] = ContactBackupEntry(
                    id: id, card: record.card, imageData: image,
                    isOrganization: record.isOrganization, groupIDs: record.groupIDs)
            } else {
                let card = ContactCard(contact, id: id, containerID: "", containerName: "", isMe: false)
                result[id] = ContactBackupEntry(
                    id: id, card: card, imageData: image, isOrganization: contact.contactType == .organization)
            }
        }
        return result
    }

    private static func value(of property: String, in line: Substring) -> String? {
        let prefix = property + ":"
        guard line.prefix(prefix.count).uppercased() == prefix else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func imageType(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8]) { return ";TYPE=JPEG" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ";TYPE=PNG" }
        return ""
    }

    /// The line folded into 75-byte pieces, each continuation starting with a space.
    private static func folded(_ line: String) -> String {
        var out = ""
        var piece = ""
        var limit = lineLimit
        for ch in line {
            if piece.utf8.count + String(ch).utf8.count > limit {
                out += piece + "\r\n "
                piece = ""
                // The leading space counts toward the next line.
                limit = lineLimit - 1
            }
            piece.append(ch)
        }
        return out + piece + "\r\n"
    }
}
