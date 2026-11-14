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
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Similar Shots: remove the extra shots of a burst, then Copies: merge a set of copies.
    /// Both go through Review and PhotoKit's own confirmation, leave a notice, and add a row
    /// to History. One launch, so the photo check runs once.
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

        XCTContext.runActivity(named: "Remove the extra shots of a burst") { _ in
            tidy.open("home.card.similar")
            tidy.open("similar.row.0")
            XCTAssertTrue(tidy.element("decision.picker").waitForExistence(timeout: 20), "No decision picker in the group")

            let primary = tidy.element("actionbar.primary")
            XCTAssertTrue(primary.waitForExistence(timeout: 20), "No action bar in the group")
            XCTAssertNotNil(
                primary.label.range(of: #"^Remove \d+ photos?$"#, options: .regularExpression),
                "Primary action reads \"\(primary.label)\", expected \"Remove N photos\""
            )
            tidy.tap("actionbar.primary")

            let title = tidy.reviewTitle()
            XCTAssertTrue(title.hasPrefix("Remove "), "Review title \"\(title)\"")
            tidy.tap("review.confirm")
            XCTAssertNotNil(
                SystemAlerts.tap(SystemAlerts.confirmDelete, in: tidy.app, timeout: 30),
                "No PhotoKit delete prompt: \(SystemAlerts.describeVisibleAlert(in: tidy.app))"
            )
            let notice = tidy.waitForNotice()
            attach(text: notice, named: "notice-similar")
            tidy.popToRoot()
        }

        XCTContext.runActivity(named: "History has a receipt for the removal") { _ in
            tidy.selectTab("tab.history", label: "History")
            XCTAssertTrue(
                tidy.until(20) { tidy.rowCount(prefixed: "history.row.") >= 1 },
                "History shows no receipt after the removal"
            )
            tidy.selectTab("tab.tidy", label: "Tidy")
        }

        XCTContext.runActivity(named: "Merge a set of copies") { _ in
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
            attach(text: prompts.joined(separator: ", "), named: "prompts-copies")
            XCTAssertNotNil(notice, "No notice after the merge")
            attach(text: notice ?? "", named: "notice-copies")
            tidy.popToRoot()
        }

        XCTContext.runActivity(named: "History has a receipt for each") { _ in
            tidy.selectTab("tab.history", label: "History")
            XCTAssertTrue(
                tidy.until(20) { tidy.rowCount(prefixed: "history.row.") >= 2 },
                "History shows \(tidy.rowCount(prefixed: "history.row.")) receipts, expected 2"
            )
        }
    }

    /// Files: move one of two identical PDFs to Holding, see it there, put everything back.
    /// Then the 120 MB sample shows under Large Files.
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
        tidy.popToRoot()

        tidy.open("home.row.largefiles")
        XCTAssertTrue(tidy.element("largefiles.row.0").waitForExistence(timeout: 30), "The 120 MB sample isn't under Large Files")
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

    /// The other two tabs open and show their screens; Tidy comes back.
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
        tidy.selectTab("tab.tidy", label: "Tidy")
        XCTAssertTrue(tidy.element("coverage.line").waitForExistence(timeout: 10), "Tidy didn't come back")
    }
}
