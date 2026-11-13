import Foundation

/// Why a file action didn't happen. Each case carries the names the UI needs to say so in a
/// sentence, such as "Couldn't move map.pdf. It's still in Trips." The words live in the UI.
///
/// Whenever one of these is thrown, the file is where it was before the call.
public enum FilesError: Error, Hashable, Sendable {
    /// The volume is full.
    case notEnoughSpace(name: String)
    /// Put back can't find the folder the file came from (it was renamed or deleted). The
    /// file stays held; the UI can ask where to put it instead.
    case originalFolderMissing(name: String, folder: String)
    /// The file isn't inside the chosen folder (or is already in "Held by Tidykeep"), so it
    /// can't be moved within it.
    case outsideFolder(name: String)
    /// The file changed, moved or vanished since the check, so the user's choice may no longer
    /// apply. Checking again shows it as it is now.
    case fileChanged(name: String)
    /// The system wouldn't let the app read this path.
    case unreadable(path: String)
    /// The move failed for another reason. `folder` is the folder the file is still in.
    case couldNotMove(name: String, folder: String)
    /// Permanent deletion failed; the file is still held.
    case couldNotDelete(name: String)
    /// The held file isn't in "Held by Tidykeep" anymore, usually because the user deleted it
    /// in the Files app. `HoldingStore.reconcile` tidies the list.
    case heldFileMissing(name: String)
    /// No held item has this id.
    case notHeld(id: UUID)
    /// The chosen folder can't be opened anymore; the user needs to choose it again.
    case folderUnavailable(name: String)
    /// The list of held files couldn't be saved, so nothing was moved.
    case couldNotSaveManifest(path: String)
}

extension FilesError {
    /// True for "disk full", however deep the system wrapped it.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }

    /// True when the error says the source file wasn't there.
    static func isNoSuchFile(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isNoSuchFile(underlying) }
        return false
    }
}
