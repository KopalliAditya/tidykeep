import XCTest

/// Xcode's accessibility audit on each main screen: Home, Similar Shots, a group, Review,
/// Holding, a contact merge, History and Rules. Contrast, hit regions, Dynamic Type,
/// clipped text, missing labels and the rest (`.all`).
///
/// Every issue is listed in an "a11y-<screen>" attachment. TK_A11Y_AUDIT (set by CI,
/// passed to the test runner): "strict" (the default) also fails the test once all its
/// screens are audited, listing every issue the app owns; "report" only attaches them.
final class AccessibilityAuditTests: XCTestCase {
    /// Issues the app owns, from every screen audited so far in this test.
    private var appIssues: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        appIssues = []
    }

    @MainActor
    func testPhotoScreens() throws {
        let tidy = AppDriver(self)
        tidy.launch()
        tidy.waitForPhotoCheck()
        try audit("home", tidy)

        tidy.open("home.card.similar")
        XCTAssertTrue(tidy.element("similar.row.0").waitForExistence(timeout: 20), "No similar groups")
        try audit("similar-list", tidy)

        tidy.open("similar.row.0")
        XCTAssertTrue(tidy.element("decision.picker").waitForExistence(timeout: 20), "No decision picker")
        try audit("group", tidy)

        tidy.tap("actionbar.primary")
        _ = tidy.reviewTitle()
        try audit("review", tidy)
        tidy.cancelReview()
        failOnAppIssues()
    }

    @MainActor
    func testHoldingContactsHistoryAndRules() throws {
        let tidy = AppDriver(self)
        tidy.launch(seeds: [.files, .contacts])

        // Holding needs something in it.
        tidy.open("home.row.dupfiles")
        tidy.open("dupfiles.row.0")
        tidy.tap("actionbar.primary", timeout: 20)
        tidy.waitForNotice()
        tidy.popToRoot()
        tidy.open("home.row.holding")
        XCTAssertTrue(tidy.element("holding.row.0").waitForExistence(timeout: 20), "Nothing in Holding")
        try audit("holding", tidy)
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
        XCTAssertTrue(tidy.element("actionbar.primary").waitForExistence(timeout: 20), "No contact merge")
        try audit("contact-merge", tidy)
        tidy.popToRoot()

        tidy.selectTab("tab.history", label: "History")
        tidy.until(10) { tidy.elements(prefixed: "history.row.").count > 0 }
        try audit("history", tidy)

        tidy.selectTab("tab.rules", label: "Rules")
        try audit("rules", tidy)
        failOnAppIssues()
    }

    // MARK: Auditing

    private var strict: Bool {
        ProcessInfo.processInfo.environment["TK_A11Y_AUDIT"]?.lowercased() != "report"
    }

    /// Audits what's on screen now and lists every issue in "a11y-<screen>". The issues the
    /// app owns are kept for `failOnAppIssues()`, so one screen's issues don't stop the
    /// audit of the next.
    @MainActor
    private func audit(_ screen: String, _ tidy: AppDriver) throws {
        // Let animations settle: a half-faded element reads as low contrast.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let chrome = systemChrome(in: tidy.app)
        var found: [String] = []
        var ignored: [String] = []

        // Returning true marks an issue as handled, so the audit itself never fails the test;
        // failOnAppIssues() does, with the whole list.
        try tidy.app.performAccessibilityAudit(for: .all) { issue in
            let what = Self.describe(issue)
            if let reason = Self.systemOwned(issue, chrome: chrome) {
                ignored.append("\(what) [ignored: \(reason)]")
            } else {
                found.append(what)
            }
            return true
        }
        appIssues += found.map { "\(screen): \($0)" }

        var note = "\(screen): \(found.count) issue(s)\n" + found.map { "- \($0)" }.joined(separator: "\n")
        if !ignored.isEmpty {
            note += "\nIgnored, owned by iOS:\n" + ignored.map { "- \($0)" }.joined(separator: "\n")
        }
        attach(text: note, named: "a11y-\(screen)")
    }

    /// In strict mode, fails the test with every issue the app owns on the screens audited.
    @MainActor
    private func failOnAppIssues(file: StaticString = #filePath, line: UInt = #line) {
        guard strict, !appIssues.isEmpty else { return }
        XCTFail(
            "\(appIssues.count) accessibility issue(s) in Tidykeep's own views:\n"
                + appIssues.map { "- \($0)" }.joined(separator: "\n"),
            file: file, line: line
        )
    }

    /// Frames of what iOS draws around the app: navigation bars, the tab bar, toolbars,
    /// the status bar, the keyboard and system alerts.
    @MainActor
    private func systemChrome(in app: XCUIApplication) -> [CGRect] {
        let queries = [app.navigationBars, app.tabBars, app.toolbars, app.statusBars, app.keyboards, app.alerts]
        return queries.flatMap { query in
            query.allElementsBoundByIndex.compactMap { $0.exists ? $0.frame : nil }
        }
    }

    /// Why an issue is iOS's rather than the app's, or nil if it's the app's to fix.
    ///
    /// Only elements with no accessibility identifier can be iOS's: every control Tidykeep
    /// draws for its own screens carries one (see the UI-test contract). Of those, an issue
    /// with no element at all, or on an element inside a navigation bar, the tab bar, a
    /// toolbar, the status bar, the keyboard or an alert, is in UIKit's chrome: the back
    /// button, the large title, the tab bar's own buttons. The app can't change how those
    /// are drawn, so failing on them would only hide its own issues behind noise.
    ///
    /// One narrower exception for the tab bar: its buttons carry Tidykeep's tab identifiers
    /// but are drawn by iOS at a fixed size, using the Large Content Viewer instead of
    /// Dynamic Type, which the audit reports as a Dynamic Type issue.
    ///
    /// An element that has gone by the time the issue is looked at counts as the app's: it
    /// can't be shown to be iOS's.
    @MainActor
    private static func systemOwned(_ issue: XCUIAccessibilityAuditIssue, chrome: [CGRect]) -> String? {
        guard let element = issue.element else { return "no element: drawn outside the app's views" }
        guard element.exists else { return nil }
        let identifier = element.identifier
        let frame = element.frame
        let inChrome = chrome.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        if issue.auditType == .dynamicType && identifier.hasPrefix("tab.") && inChrome {
            return "tab bar button, sized by iOS"
        }
        if identifier.isEmpty && inChrome {
            return "system bar or alert"
        }
        return nil
    }

    @MainActor
    private static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        var text = "\(issue.compactDescription) (\(name(of: issue.auditType)))"
        if let element = issue.element, element.exists {
            let id = element.identifier.isEmpty ? "no identifier" : element.identifier
            text += " on \(element.elementType.rawValue)/\(id) \"\(element.label)\""
        }
        return text
    }

    @MainActor
    private static func name(of type: XCUIAccessibilityAuditType) -> String {
        let names: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "element detection"), (.hitRegion, "hit region"),
            (.sufficientElementDescription, "description"), (.dynamicType, "Dynamic Type"),
            (.textClipped, "text clipped"), (.trait, "trait"),
        ]
        return names.first { type.contains($0.0) }?.1 ?? "type \(type.rawValue)"
    }
}
