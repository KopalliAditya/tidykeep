import Foundation

/// The visible folder that held files go to, one at the root of each chosen folder.
///
/// Keeping it inside the chosen folder makes a move a rename on the same volume: instant, and
/// needing no free space. Keeping it visible means the user can see and empty it in the Files
/// app without Tidykeep.
public enum HoldingFolder: Sendable {
    /// The folder's name on disk. It is never translated: the scanner finds the folder by this
    /// name, and a folder made in one language must still be found after a language change.
    public static let name = "Held by Tidykeep"

    /// Where the folder is (or will be) for a chosen folder.
    public static func url(in folderRoot: URL) -> URL {
        folderRoot.appendingPathComponent(name, isDirectory: true)
    }

    /// True for the folder's name in any letter case, since the volume may ignore case.
    static func matches(_ folderName: String) -> Bool {
        folderName.compare(name, options: .caseInsensitive) == .orderedSame
    }
}

/// Free file names in the style of the Files app: "map.pdf", then "map 2.pdf", "map 3.pdf".
enum UniqueName {
    /// The first name free in `folder` that isn't in `taken` either. `taken` covers names the
    /// holding list still points at, so a vanished held file's name isn't reused before the list
    /// is reconciled. Only something seen at a path makes its name taken: a folder that can't
    /// be looked into would otherwise make every name look taken.
    static func pick(for name: String, in folder: URL, avoiding taken: Set<String> = []) -> String {
        let taken = Set(taken.map { $0.lowercased() })
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = name
        var number = 2
        while taken.contains(candidate.lowercased())
            || FileFacts.status(of: folder.appendingPathComponent(candidate, isDirectory: false)) != nil {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        return candidate
    }
}
