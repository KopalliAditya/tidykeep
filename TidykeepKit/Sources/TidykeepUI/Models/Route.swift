import Foundation

/// Every screen a tab's `NavigationStack` can push. Codable, so a path could be restored.
enum Route: Hashable, Codable {
    // Photos
    case similar
    case similarGroup(String)
    case copies
    case copySet(String)
    case screenshots
    case videos
    case video(String)
    // Files
    case duplicateFiles
    case duplicateFileSet(String)
    case largeFiles
    case holding
    // Contacts
    case contacts
    case contactMerge(String)
    // History and Rules
    case receipt(UUID)
    case albums
    case about
    case privacyPolicy
    case acknowledgements
}

enum AppTab: String, Hashable {
    case tidy, history, rules
}
