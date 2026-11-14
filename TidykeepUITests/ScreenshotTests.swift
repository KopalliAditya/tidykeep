import XCTest

/// The screens worth looking at, kept in the result bundle as "01-home" ... "10-rules"
/// (CI exports them into the "screenshots" artifact), plus Home and a group in dark mode.
///
/// Nothing photo-related is removed or merged here: Review is left with Cancel, and the
/// file moved to Holding for its screenshot is put back. CI runs these before
/// EndToEndUITests so the shots show the whole seeded library.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Back to light, even when the dark pass failed halfway.
    override func tearDown() async throws {
        await MainActor.run { XCUIDevice.shared.appearance = .light }
        try await super.tearDown()
    }

    /// Home, Similar Shots, a group, Review, Copies; then Home and the group again in dark.
    @MainActor
    func testPhotoScreens() throws {
        let tidy = AppDriver(self)
        XCUIDevice.shared.appearance = .light
        tidy.launch()
        tidy.waitForPhotoCheck()
        tidy.screenshot("01-home")

        tidy.open("home.card.similar")
        XCTAssertTrue(tidy.element("similar.row.0").waitForExistence(timeout: 20), "No similar groups")
        tidy.screenshot("02-similar")

        tidy.open("similar.row.0")
        XCTAssertTrue(tidy.element("decision.picker").waitForExistence(timeout: 20), "No decision picker")
        tidy.screenshot("03-group")

        tidy.tap("actionbar.primary")
        _ = tidy.reviewTitle()
        tidy.screenshot("04-review")
        tidy.cancelReview()
        tidy.popToRoot()

        tidy.open("home.card.copies")
        tidy.open("copies.row.0")
        XCTAssertTrue(tidy.element("actionbar.primary").waitForExistence(timeout: 20), "No copy set to show")
        tidy.screenshot("05-copies")
        tidy.popToRoot()

        // The dark pass. The simulator's appearance changes live, so no relaunch and no
        // second photo check. If it won't switch, the app is relaunched dark instead.
        XCUIDevice.shared.appearance = .dark
        if XCUIDevice.shared.appearance != .dark {
            attach(text: "XCUIDevice couldn't switch to dark; relaunched with -TKAppearance dark", named: "dark-mode")
            tidy.launch(appearance: "dark")
            tidy.waitForPhotoCheck()
        }
        XCTAssertTrue(tidy.element("coverage.line").waitForExistence(timeout: 10))
        tidy.screenshot("01-home-dark")
        tidy.open("home.card.similar")
        tidy.open("similar.row.0")
        XCTAssertTrue(tidy.element("decision.picker").waitForExistence(timeout: 20), "No decision picker")
        tidy.screenshot("03-group-dark")
        tidy.popToRoot()
        XCUIDevice.shared.appearance = .light
    }

    /// Duplicate files, Holding, a contact merge, History and Rules.
    @MainActor
    func testFilesContactsHistoryAndRules() throws {
        let tidy = AppDriver(self)
        XCUIDevice.shared.appearance = .light
        tidy.launch(seeds: [.files, .contacts])

        tidy.open("home.row.dupfiles")
        tidy.open("dupfiles.row.0")
        XCTAssertTrue(tidy.element("actionbar.primary").waitForExistence(timeout: 20), "No duplicate files to show")
        tidy.screenshot("06-files")
        tidy.tap("actionbar.primary")
        tidy.waitForNotice()
        tidy.popToRoot()

        tidy.open("home.row.holding")
        XCTAssertTrue(tidy.element("holding.row.0").waitForExistence(timeout: 20), "Nothing in Holding")
        tidy.screenshot("07-holding")
        // Leave the sample folder as it was.
        let putBack = tidy.element("actionbar.secondary")
        XCTAssertTrue(putBack.waitForExistence(timeout: 10), "No Put all back")
        let barFrame = putBack.frame
        tidy.tap("actionbar.secondary")
        tidy.dialogButton("Put all back", notAt: barFrame, timeout: 3)?.tap()
        tidy.until(20) { !tidy.element("holding.row.0").exists }
        tidy.popToRoot()

        tidy.open("home.row.contacts")
        tidy.passContactsPermission()
        tidy.open("contacts.row.0")
        XCTAssertTrue(tidy.element("actionbar.primary").waitForExistence(timeout: 20), "No contact merge to show")
        tidy.screenshot("08-contacts-merge")
        tidy.popToRoot()

        tidy.selectTab("tab.history", label: "History")
        // Moving the file to Holding and putting it back left receipts.
        tidy.until(10) { tidy.elements(prefixed: "history.row.").count > 0 }
        tidy.screenshot("09-history")

        tidy.selectTab("tab.rules", label: "Rules")
        tidy.screenshot("10-rules")
    }
}
