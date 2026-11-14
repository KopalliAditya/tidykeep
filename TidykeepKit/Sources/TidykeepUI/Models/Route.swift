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
    case ruleChoice(RuleChoice)
    case about
    case privacyPolicy
    case acknowledgements
}

/// A rule with a few choices, each listed on a screen of its own from Rules.
enum RuleChoice: String, Hashable, Codable, CaseIterable {
    case scope, sensitivity, videoMinimum, largeFileMinimum
}

enum AppTab: String, Hashable {
    case tidy, history, rules
}
