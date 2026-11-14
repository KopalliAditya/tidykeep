import XCTest

/// Photos and contacts turned down at the system prompts, the way a person might.
///
/// The app says access is off and offers Settings, Duplicate Files still works, and it
/// doesn't ask again on the next launch. This needs access that was never answered, so CI
/// runs it last, after `grant-privacy.sh --reset` and with TK_ACCESS_RESET set; it leaves
/// both turned down. Anywhere else it skips, since the other tests need access granted.
final class PermissionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TK_ACCESS_RESET"] == "1",
            "Needs photo and contacts access reset first (grant-privacy.sh --reset, then TK_ACCESS_RESET=1)"
        )
    }

    @MainActor
    func testTurningDownPhotosAndContacts() throws {
        let tidy = AppDriver(self)
        // Onboarding's Continue asks for photos; the prompt is left for the test to answer.
        tidy.launch(seeds: .files, answeringPhotoPrompt: false, marker: "home.row.dupfiles")

        XCTContext.runActivity(named: "Turn down photos") { _ in
            XCTAssertNotNil(
                SystemAlerts.tap(SystemAlerts.denyAccess, in: tidy.app, timeout: 30),
                "No photo prompt to turn down: \(SystemAlerts.describeVisibleAlert(in: tidy.app))"
            )
            XCTAssertTrue(
                tidy.app.staticTexts["Photos access is off"].waitForExistence(timeout: 20),
                "Tidy doesn't say photo access is off"
            )
            XCTAssertTrue(tidy.app.buttons["Open Settings"].exists, "No Open Settings with photo access off")
            XCTAssertFalse(tidy.element("coverage.line").exists, "A coverage line with photo access off")
            XCTAssertFalse(tidy.element("home.card.similar").exists, "Photo cards with photo access off")
            tidy.screenshot("permissions-photos-off")
        }

        XCTContext.runActivity(named: "Duplicate Files still works") { _ in
            tidy.open("home.row.dupfiles")
            XCTAssertTrue(
                tidy.element("dupfiles.row.0").waitForExistence(timeout: 30),
                "No duplicate files with photo access off"
            )
            tidy.popToRoot()
        }

        XCTContext.runActivity(named: "Turn down contacts") { _ in
            tidy.open("home.row.contacts")
            tidy.tap("contacts.continue")
            XCTAssertNotNil(
                SystemAlerts.tap(SystemAlerts.denyAccess, in: tidy.app, timeout: 30),
                "No contacts prompt to turn down: \(SystemAlerts.describeVisibleAlert(in: tidy.app))"
            )
            XCTAssertTrue(
                tidy.app.staticTexts["Contacts access is off"].waitForExistence(timeout: 20),
                "Duplicate Contacts doesn't say contacts access is off"
            )
            tidy.screenshot("permissions-contacts-off")
            tidy.popToRoot()

            let row = tidy.element("home.row.contacts")
            var label = ""
            let says = tidy.until(10) {
                label = row.exists ? row.label : ""
                return label.contains("Contacts access is off")
            }
            XCTAssertTrue(says, "The Duplicate Contacts row reads \"\(label)\"")
        }

        XCTContext.runActivity(named: "Launch again: no prompt") { _ in
            // A fresh install of the app's own data, so onboarding's Continue asks for
            // photos again; iOS remembers the answer and shows nothing.
            tidy.launch(answeringPhotoPrompt: false, marker: "home.row.dupfiles")
            let asked = tidy.until(5) {
                SystemAlerts.springboard.alerts.firstMatch.exists || tidy.app.alerts.firstMatch.exists
            }
            XCTAssertFalse(asked, "A prompt after access was turned down: \(SystemAlerts.describeVisibleAlert(in: tidy.app))")
            XCTAssertTrue(
                tidy.app.staticTexts["Photos access is off"].waitForExistence(timeout: 20),
                "Tidy doesn't say photo access is off after a new launch"
            )

            tidy.open("home.row.contacts")
            XCTAssertTrue(
                tidy.app.staticTexts["Contacts access is off"].waitForExistence(timeout: 20),
                "Duplicate Contacts doesn't say contacts access is off after a new launch"
            )
            XCTAssertFalse(tidy.element("contacts.continue").exists, "Duplicate Contacts offers to ask again")
            XCTAssertFalse(
                SystemAlerts.springboard.alerts.firstMatch.exists,
                "A prompt in Duplicate Contacts: \(SystemAlerts.describeVisibleAlert(in: tidy.app))"
            )
            tidy.popToRoot()
        }
    }
}
