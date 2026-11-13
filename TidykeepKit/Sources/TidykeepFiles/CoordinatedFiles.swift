import Foundation

/// Moves and deletes through `NSFileCoordinator`.
///
/// Coordination tells the file's provider (iCloud Drive, an external drive's app) and any open
/// document about the change, so it's applied as a rename on their side rather than seen as a
/// file that vanished and another that appeared.
enum CoordinatedFiles {
    /// Renames `source` to `destination`, which must not exist. Never overwrites.
    static func move(_ source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var moveError: (any Error)?
        coordinator.coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            do {
                coordinator.item(at: from, willMoveTo: to)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        if let error = coordinationError ?? moveError { throw error }
    }

    /// Deletes `url` for good. Nothing goes to a trash.
    static func delete(_ url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var deleteError: (any Error)?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                deleteError = error
            }
        }
        if let error = coordinationError ?? deleteError { throw error }
    }
}
