import XCTest

/// Every Tidykeep flow driven the way a person would, on the CI simulator.
///
/// The photo library is seeded by CI (three bursts, three sets of re-saved copies, six
/// screenshots, two long videos); files and contacts are seeded by the app itself when
/// launched with -TKSeedFiles YES and -TKSeedContacts YES. Each test starts from a fresh
/// install of the app's own data (-TKResetState YES). Removing photos really moves them to
/// Recently Deleted, so later runs on the same simulator see one burst and one copy set
/// fewer; the seed has three of each for that reason, and CI runs these tests after the
/// screenshots and the accessibility audit.
final class EndToEndUITests: XCTestCase {
    /// The no in PhotoKit's prompt, spelled with a straight or a curly apostrophe.
    private static let refuse = ["Don't Allow", "Don\u{2019}t Allow"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Similar Shots: say no to PhotoKit once, then remove the extra shots of a burst. Copies:
    /// merge a set of copies, which has no Undo since the seed puts no copy in an album. Both
    /// go through Review and PhotoKit's own confirmation, leave a notice, and add a row to
    /// History. One launch, so the photo check runs once.
    @MainActor
    func testRemoveSimilarShotsAndMergeCopies() throws {
        let tidy = AppDriver(self)
        tidy.launch()
        let checked = tidy.waitForPhotoCheck()
        attach(text: checked, named: "coverage")

        XCTContext.runActivity(named: "Screenshots and Big Videos open") { _ in
            // Photos decides for itself whether an imported PNG is a screenshot, so an empty
            // Screenshots list is recorded rather than failed; PhotoKitIntegrationTests
            // reports how many were marked.
            tidy.open("home.card.screenshots")
            let tile = tidy.element("screenshot.tile.0")
            let empty = tidy.allTidy()
            var shown: String?
            tidy.until(20) {
                if tile.exists {
                    shown = "screenshot.tile.0"
                } else if empty.exists {
                    shown = "All tidy"
                }
                return shown != nil
            }
            XCTAssertNotNil(shown, "The Screenshots screen showed neither a screenshot nor \"All tidy\"")
            attach(text: shown ?? "nothing", named: "screenshots-first")
            tidy.popToRoot()

            // The two seeded videos are 64 and 75 seconds long: over the 1 minute default.
            tidy.open("home.card.videos")
            XCTAssertTrue(tidy.element("video.row.0").waitForExistence(timeout: 20), "No video over a minute in Big Videos")
            tidy.popToRoot()
        }

        let photos = XCTContext.runActivity(named: "Remove the extra shots of a burst") { _ -> String in
            tidy.open("home.card.similar")
            tidy.open("similar.row.0")
            let picker = tidy.element("decision.picker")
            XCTAssertTrue(picker.waitForExistence(timeout: 20), "No decision picker in the group")

            let primary = tidy.element("actionbar.primary")
            XCTAssertTrue(primary.waitForExistence(timeout: 20), "No action bar in the group")
            let action = primary.label
            XCTAssertNotNil(
                action.range(of: #"^Remove \d+ photos?$"#, options: .regularExpression),
                "Primary action reads \"\(action)\", expected \"Remove N photos\""
            )
            // "4 photos" or "1 photo": the notice and History count them the same way.
            let photos = String(action.dropFirst("Remove ".count))

            // Don't Allow first: nothing goes, and the group stays open as it was.
            tidy.tap("actionbar.primary")
            let title = tidy.reviewTitle()
            XCTAssertTrue(title.hasPrefix("Remove "), "Review title \"\(title)\"")
            tidy.tap("review.confirm")
            XCTAssertNotNil(
                SystemAlerts.tap(Self.refuse, in: tidy.app, timeout: 30),
                "No PhotoKit delete prompt to say no to: \(SystemAlerts.describeVisibleAlert(in: tidy.app))"
            )
            let refused = tidy.waitForNotice()
            attach(text: refused, named: "notice-similar-refused")
            XCTAssertEqual(refused, "Nothing removed.")
            XCTAssertTrue(picker.waitForExistence(timeout: 20), "The group closed after Don't Allow")
            XCTAssertTrue(
                tidy.until(10) { primary.exists && primary.label == action },
                "Primary action reads \"\(primary.label)\" after Don't Allow, expected \"\(action)\""
            )

            // Then for real.
            tidy.tap("actionbar.primary")
            let again = tidy.reviewTitle()
            XCTAssertTrue(again.hasPrefix("Remove "), "Review title \"\(again)\"")
            tidy.tap("review.confirm")
            XCTAssertNotNil(
                SystemAlerts.tap(SystemAlerts.confirmDelete, in: tidy.app, timeout: 30),
                "No PhotoKit delete prompt: \(SystemAlerts.describeVisibleAlert(in: tidy.app))"
            )
            let notice = nextNotice(after: refused, tidy)
            attach(text: notice, named: "notice-similar")
            XCTAssertTrue(notice.hasPrefix("Removed \(photos)."), "Notice reads \"\(notice)\", expected \"Removed \(photos).\"")
            tidy.popToRoot()
            return photos
        }

        XCTContext.runActivity(named: "History has a receipt for the removal") { _ in
            tidy.selectTab("tab.history", label: "History")
            // Newest first, so the removal is the top row.
            XCTAssertTrue(
                tidy.until(20) { newestReceipt(tidy).hasPrefix("Removed \(photos).") },
                "History's top row reads \"\(newestReceipt(tidy))\", expected \"Removed \(photos).\""
            )
            // Don't Allow left no receipt, so the removal is the only one.
            XCTAssertEqual(tidy.rowCount(prefixed: "history.row."), 1, "Don't Allow left a receipt in History")
            tidy.selectTab("tab.tidy", label: "Tidy")
        }

        let copies = XCTContext.runActivity(named: "Merge a set of copies") { _ -> String in
            // Removing photos starts a fresh check of what changed.
            tidy.waitForPhotoCheck()
            tidy.open("home.card.copies")
            tidy.open("copies.row.0")

            let primary = tidy.element("actionbar.primary")
            XCTAssertTrue(primary.waitForExistence(timeout: 20), "No action bar in the copy set")
            XCTAssertTrue(primary.label.hasPrefix("Merge"), "Primary action reads \"\(primary.label)\", expected \"Merge\"")
            tidy.tap("actionbar.primary")

            let title = tidy.reviewTitle()
            XCTAssertTrue(title.hasPrefix("Merge "), "Review title \"\(title)\"")
            tidy.tap("review.confirm")
            // A merge can ask twice: once to change the copy it keeps, once to delete the rest.
            let (prompts, notice) = tidy.confirmPhotoPrompts()
            XCTAssertFalse(
                prompts.isEmpty,
                "No PhotoKit prompt for the merge: \(SystemAlerts.describeVisibleAlert(in: tidy.app))"
            )
            XCTAssertNotNil(notice, "No notice after the merge")
            let merged = notice ?? ""
            // The seed puts no copy in an album or favorites, so the kept copy joined no album
            // and there's nothing for Undo to take back: the notice has none. It goes four
            // seconds after it shows, so this looks while it's still up.
            let offersUndo = tidy.until(2, every: 0.25) { tidy.noticeOffersUndo(merged) }
            attach(text: prompts.joined(separator: ", "), named: "prompts-copies")
            attach(text: merged, named: "notice-copies")
            XCTAssertFalse(offersUndo, "The notice \"\(merged)\" offers Undo, but the merge added the kept copy to no album")
            XCTAssertTrue(merged.hasPrefix("Merged 1 set."), "Notice reads \"\(merged)\", expected \"Merged 1 set.\"")
            // "The 2 copies removed are in Recently Deleted": History counts them the same way.
            let copies = merged.range(of: #"\d+ cop(y|ies)"#, options: .regularExpression).map { String(merged[$0]) } ?? ""
            XCTAssertFalse(copies.isEmpty, "The notice \"\(merged)\" doesn't say how many copies went")
            tidy.popToRoot()
            return copies
        }

        XCTContext.runActivity(named: "History has a receipt for each") { _ in
            tidy.selectTab("tab.history", label: "History")
            XCTAssertTrue(
                tidy.until(20) { tidy.rowCount(prefixed: "history.row.") >= 2 },
                "History shows \(tidy.rowCount(prefixed: "history.row.")) receipts, expected 2"
            )
            // With no Undo, the merge stays done, and its row says until when the removed
            // copies are in Recently Deleted.
            XCTAssertTrue(
                tidy.until(20) {
                    let top = newestReceipt(tidy)
                    return top.hasPrefix("Merged \(copies).") && top.contains(". In Recently Deleted until ")
                },
                "History's top row reads \"\(newestReceipt(tidy))\", expected \"Merged \(copies).\", in Recently Deleted"
            )
        }
    }

    /// Files: move one of two identical PDFs to Holding, see it there, put everything back,
    /// and the set is back under Duplicate Files. Then hold it again and empty Holding: the
    /// file is deleted for good, the set is gone, and History says so. The 120 MB sample
    /// shows under Large Files.
    @MainActor
    func testFilesHoldingAndPutBack() throws {
        let tidy = AppDriver(self)
        tidy.launch(seeds: .files)

        tidy.open("home.row.dupfiles")
        tidy.open("dupfiles.row.0")
        let primary = tidy.element("actionbar.primary")
        XCTAssertTrue(primary.waitForExistence(timeout: 20), "No action bar for the duplicate files")
        XCTAssertEqual(primary.label, "Move 1 to Holding")
        tidy.tap("actionbar.primary")

        let notice = tidy.waitForNotice()
        attach(text: notice, named: "notice-files")
        XCTAssertTrue(tidy.noticeOffersUndo(notice), "The notice \"\(notice)\" offers no Undo")
        tidy.popToRoot()

        tidy.open("home.row.holding")
        XCTAssertTrue(tidy.element("holding.row.0").waitForExistence(timeout: 20), "Nothing in Holding after the move")
        let putBack = tidy.element("actionbar.secondary")
        XCTAssertTrue(putBack.waitForExistence(timeout: 10), "No Put all back")
        XCTAssertEqual(putBack.label, "Put all back")
        XCTAssertEqual(tidy.element("actionbar.primary").label, "Empty Holding")
        let barFrame = putBack.frame
        tidy.tap("actionbar.secondary")
        // A confirmation, if the app asks, repeats the label.
        tidy.dialogButton("Put all back", notAt: barFrame, timeout: 3)?.tap()
        XCTAssertTrue(
            tidy.until(20) { !tidy.element("holding.row.0").exists },
            "Holding still lists files after Put all back"
        )
        XCTAssertTrue(tidy.element("holding.empty").waitForExistence(timeout: 20), "Holding isn't empty after Put all back")
        tidy.popToRoot()

        // Putting back checks the folders again, so the set comes back.
        tidy.open("home.row.dupfiles")
        XCTAssertTrue(tidy.element("dupfiles.row.0").waitForExistence(timeout: 30), "The set isn't back under Duplicate Files")

        // Hold it again, then empty Holding, which deletes the file for good.
        tidy.open("dupfiles.row.0")
        XCTAssertTrue(primary.waitForExistence(timeout: 20), "No action bar for the duplicate files")
        XCTAssertEqual(primary.label, "Move 1 to Holding")
        tidy.tap("actionbar.primary")
        let held = nextNotice(after: "Put back 1 file.", tidy)
        XCTAssertTrue(held.hasPrefix("Moved 1 file to Holding."), "Notice reads \"\(held)\"")
        tidy.popToRoot()

        tidy.open("home.row.holding")
        XCTAssertTrue(tidy.element("holding.row.0").waitForExistence(timeout: 20), "Nothing in Holding after the second move")
        XCTAssertTrue(primary.waitForExistence(timeout: 10), "No Empty Holding")
        XCTAssertEqual(primary.label, "Empty Holding")
        tidy.tap("actionbar.primary")
        XCTAssertEqual(tidy.reviewTitle(), "Remove 1 file for good?")
        XCTAssertEqual(tidy.element("review.confirm").label, "Delete 1 file")
        tidy.tap("review.confirm")
        let deleted = nextNotice(after: held, tidy)
        attach(text: deleted, named: "notice-files-delete")
        XCTAssertTrue(deleted.hasPrefix("Deleted 1 file."), "Notice reads \"\(deleted)\"")
        XCTAssertTrue(tidy.element("holding.empty").waitForExistence(timeout: 20), "Holding isn't empty after Empty Holding")
        tidy.popToRoot()

        // Only its twin is left, so there's no set to list.
        tidy.open("home.row.dupfiles")
        XCTAssertTrue(tidy.allTidy().waitForExistence(timeout: 30), "Duplicate Files isn't all tidy after the delete")
        XCTAssertFalse(tidy.element("dupfiles.row.0").exists, "Duplicate Files still lists the set")
        tidy.popToRoot()

        tidy.open("home.row.largefiles")
        XCTAssertTrue(tidy.element("largefiles.row.0").waitForExistence(timeout: 30), "The 120 MB sample isn't under Large Files")
        tidy.popToRoot()

        // Newest first, so the delete is the top row.
        tidy.selectTab("tab.history", label: "History")
        XCTAssertTrue(
            tidy.until(20) { newestReceipt(tidy).hasPrefix("Deleted 1 file.") },
            "History's top row reads \"\(newestReceipt(tidy))\", expected \"Deleted 1 file.\""
        )
    }

    /// Contacts: merge the two "Jordan Rivera" cards. The backup and undo are checked
    /// against the address book itself in TidykeepAppTests.
    @MainActor
    func testMergeDuplicateContacts() throws {
        let tidy = AppDriver(self)
        tidy.launch(seeds: .contacts)

        tidy.open("home.row.contacts")
        tidy.passContactsPermission()
        tidy.open("contacts.row.0")
        let primary = tidy.element("actionbar.primary")
        XCTAssertTrue(primary.waitForExistence(timeout: 20), "No action bar for the duplicate cards")
        XCTAssertTrue(primary.label.hasPrefix("Merge"), "Primary action reads \"\(primary.label)\"")
        let barFrame = primary.frame
        tidy.tap("actionbar.primary")

        let confirm = tidy.dialogButton("Merge anyway", notAt: barFrame, timeout: 10)
        XCTAssertNotNil(confirm, "No \"Merge anyway\" confirmation")
        confirm?.tap()
        let notice = tidy.waitForNotice()
        XCTAssertTrue(notice.hasPrefix("Merged 2 cards"), "Notice reads \"\(notice)\"")

        // Put the second card back, so a later run that seeds contacts finds both. Only
        // possible when Undo is its own button; -TKSeedContacts tops the pair up otherwise.
        tidy.undoButton()?.tap()
    }

    /// The other two tabs open and show their screens, a rule's choice sticks, and Tidy comes back.
    @MainActor
    func testHistoryAndRulesTabsOpen() throws {
        let tidy = AppDriver(self)
        tidy.launch()

        for (identifier, label) in [("tab.history", "History"), ("tab.rules", "Rules")] {
            tidy.selectTab(identifier, label: label)
            let opened = tidy.until(10) {
                let bar = tidy.app.navigationBars[label]
                if bar.exists { return true }
                for tab in [tidy.app.tabBars.buttons[identifier], tidy.app.tabBars.buttons[label]] where tab.exists {
                    if tab.isSelected { return true }
                }
                return false
            }
            XCTAssertTrue(opened, "\(label) didn't open")
            let coverage = tidy.element("coverage.line")
            XCTAssertFalse(coverage.exists && coverage.isHittable, "Still on Tidy after tapping \(label)")
        }

        // Choosing goes back to Rules, and the choice is marked when the list opens again.
        tidy.tap("rules.choice.videoMinimum")
        tidy.tap("rules.option.1")
        XCTAssertTrue(tidy.until(10) { !tidy.element("rules.option.1").exists }, "Choosing didn't go back to Rules")
        tidy.tap("rules.choice.videoMinimum")
        XCTAssertTrue(tidy.until(10) { tidy.element("rules.option.1").isSelected }, "The choice didn't stick")
        tidy.back()
        tidy.selectTab("tab.tidy", label: "Tidy")
        XCTAssertTrue(tidy.element("coverage.line").waitForExistence(timeout: 10), "Tidy didn't come back")
    }

    // MARK: Helpers

    /// Waits for a notice other than `previous` and returns its text. The last notice can
    /// still show, or be on its way out, when the next one comes, so its text is skipped.
    @MainActor
    private func nextNotice(
        after previous: String, _ tidy: AppDriver, timeout: TimeInterval = 30,
        file: StaticString = #filePath, line: UInt = #line
    ) -> String {
        let next = tidy.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'notice.banner' AND label != %@", previous))
            .firstMatch
        var label = ""
        let shown = tidy.until(timeout, every: 0.25) {
            guard next.exists else { return false }
            label = next.label
            return true
        }
        XCTAssertTrue(shown, "No notice after \"\(previous)\"", file: file, line: line)
        return label
    }

    /// The words of History's top row, the newest change ("Removed 4 photos. Nov 14, …"),
    /// or "" if there's none. SwiftUI can hand a row's identifier down to the views inside
    /// it, so the first one with words is used.
    @MainActor
    private func newestReceipt(_ tidy: AppDriver) -> String {
        tidy.elements(prefixed: "history.row.").allElementsBoundByIndex.first { !$0.label.isEmpty }?.label ?? ""
    }
}
