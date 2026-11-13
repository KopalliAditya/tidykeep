import Foundation
import TidykeepCore

extension Copy {
    /// The Rules tab: what's always kept, what the app looks at, folders, contacts, haptics and
    /// saved data.
    enum Rules {
        // MARK: Always keep

        static let alwaysKeep = "Always keep"
        static let always = "Always"
        static let neverChecked = "Never checked"
        static let favorites = "Favorites"
        static let edited = "Edited photos"
        static let hidden = "Hidden photos"
        static let albums = "Albums"
        static let noAlbums = "None"
        static func albumsChosen(_ n: Int) -> String { n == 0 ? noAlbums : n.formatted() }
        static let screenshotsInAlbums = "Screenshots in albums"
        static let recentFiles = "Files changed in the last 7 days"
        static let myCard = "My Card"
        static let alwaysKeepFooter = "These are never suggested. You can still delete them yourself in Photos, Files or Contacts."

        // MARK: What to look at

        static let whatToLookAt = "What to look at"
        static let photosFrom = "Photos from"
        static let howAlike = "How alike"
        static let bigVideos = "Big videos over"
        static let largeFiles = "Large files over"
        static let takesEffect = "Takes effect next time you check."

        // MARK: Folders

        static let folders = "Folders"
        static let noFolders = "No folders chosen"
        static let addFolder = "Add folder…"
        static let removeFolder = "Stop checking"
        static let foldersFooter = "\(appName) only looks inside folders you choose. Files only in iCloud are skipped, never downloaded."

        // MARK: Contacts

        static let contacts = "Contacts"
        static let contactsAccess = "Access"
        static func access(_ access: ContactsModel.Access) -> String {
            switch access {
            case .notDetermined: "Not asked yet"
            case .denied: Copy.General.off
            case .allowed: "Allowed"
            }
        }
        static let contactsFooter = "With My Card on, your own card is never part of a merge. Either way, it's always the card that stays."

        // MARK: Haptics

        static let haptics = "Haptics"
        static let hapticsFooter = "A light tap when you mark, keep or finish something."

        // MARK: Saved data

        static let savedData = "Saved data"
        static let forgetAnalysis = "Forget saved analysis"
        static let forgetTitle = "Forget saved analysis?"
        static let forgetMessage = "Your photos aren't touched. \(appName) checks them again from the start."
        static let forgetConfirm = "Forget and check again"
        static let clearHistory = "Clear history"
        static let clearTitle = "Clear history?"
        static let clearMessage = "Your photos, files and contacts aren't touched, but past changes can no longer be undone from History."
        static let clearConfirm = "Clear history"
        static let savedDataFooter = "Saved analysis lets a check pick up where it left off. Both stay on this iPhone."

        // MARK: About

        static let about = "About"
        static func aboutApp() -> String { "About \(appName)" }
        static let version = "Version"

        // MARK: Album picker

        static let albumsFooter = "Every photo in an album you choose is kept: it's never suggested for removal."
        static let noAlbumsTitle = "No albums"
        static let noAlbumsDetail = "Albums you make in Photos show up here."
        static let photosOffDetail = "Allow photos to choose albums to keep."
        static let searchAlbums = "Search albums"
        static let kept = "Kept"
    }

    enum About {
        /// Placeholder address. Replace it with the real support address before submitting to
        /// the App Store.
        static let supportEmail = "support@tidykeep.app"

        static let free = "Free. No purchases, ads, tips or subscriptions."
        static let tagline = "Nothing changes without you, and everything can be traced."

        static let privacy = "Privacy"
        static let privacyBullets: [(symbol: String, text: String)] = [
            ("iphone", "Everything happens on this iPhone. Photos, files and contacts never leave it."),
            ("wifi.slash", "\(appName) makes no network requests and never downloads from iCloud."),
            ("person.crop.circle.badge.xmark", "No account and no sign-in."),
            ("eye.slash", "No analytics, ads or tracking."),
        ]

        static let cantDo = "What \(appName) can't do"
        static let cantDoBullets: [(symbol: String, text: String)] = [
            ("icloud.slash", "See photos or files stored only in iCloud. It never downloads them, so they're skipped."),
            ("note.text", "Read notes on contact cards it removes in a merge, so it asks before every merge."),
            ("trash.slash", "Bring photos back after Recently Deleted in Photos empties, \(Receipt.recentlyDeletedDays) days after removal."),
            ("internaldrive", "Clear caches, System Data, Messages attachments or other apps' data. For those, see Settings, General, iPhone Storage."),
        ]

        static let documents = "Documents"
        static let privacyPolicy = "Privacy policy"
        static let acknowledgements = "Acknowledgements"

        static let support = "Support"
        static let supportFooter = "Touch and hold the address to copy it."
        static func supportLabel() -> String { "Support email, \(supportEmail)" }
    }
}
