import Foundation

/// Folders that are really one document, such as a Final Cut library, a Logic project or an
/// Xcode project, even when the system doesn't know it.
///
/// The system treats a folder as a package only when an app on the device declares its type.
/// A Final Cut library synced through iCloud Drive to an iPhone without Final Cut is a plain
/// folder there, and moving one part out of it (a "duplicate" clip among its media) breaks the
/// project for good. So a folder whose name ends in a dot and a short word, such as
/// "Edit.fcpbundle" or "Song.logicx", counts as a package too.
///
/// The cost is that a folder the user happened to name "Trip.Japan" isn't checked. Leaving a
/// folder unchecked is the safe mistake; breaking a project is not.
enum PackageFolder {
    /// True for a folder name ending in "." and up to 32 ASCII letters and digits, at least one
    /// of them a letter. "Photos 2024.10" stays a plain folder.
    static func matches(_ folderName: String) -> Bool {
        let ending = (folderName as NSString).pathExtension
        guard !ending.isEmpty, ending.count <= 32 else { return false }
        return ending.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && ending.contains { $0.isLetter }
    }
}
