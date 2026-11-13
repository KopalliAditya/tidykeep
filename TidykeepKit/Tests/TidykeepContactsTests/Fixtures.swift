import Foundation
import TidykeepContacts

/// A card for tests. Phones and emails are given as plain strings; labels default to none.
func card(
    _ id: String, in container: String = "phone", isMe: Bool = false,
    given: String = "", middle: String = "", family: String = "", suffix: String = "",
    nickname: String = "", org: String = "", department: String = "", title: String = "",
    phones: [String] = [], emails: [String] = [],
    birthday: DateComponents? = nil, hasImage: Bool = false
) -> ContactCard {
    ContactCard(
        id: id, containerID: container, containerName: container.capitalized, isMe: isMe,
        givenName: given, middleName: middle, familyName: family, nameSuffix: suffix,
        nickname: nickname, organization: org, department: department, jobTitle: title,
        phones: phones.map { LabeledValue(value: $0) },
        emails: emails.map { LabeledValue(value: $0) },
        birthday: birthday, hasImage: hasImage
    )
}

/// The card with another identifier, for comparing a re-created card with its original.
func renamed(_ card: ContactCard, to id: String) -> ContactCard {
    var copy = card
    copy.id = id
    return copy
}

let jpegA = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0xA1, count: 300))
let jpegB = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0xB2, count: 300))
