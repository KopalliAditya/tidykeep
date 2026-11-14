import UIKit
import XCTest

/// Xcode's accessibility audit on each main screen: Home, Similar Shots, a group, Review,
/// Holding, a contact merge, History, Rules and a rule's choices. Contrast, hit regions, Dynamic Type,
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
        attach(text: tidy.app.debugDescription, named: "tree-rules")
        try audit("rules", tidy)

        tidy.open("rules.choice.sensitivity")
        XCTAssertTrue(tidy.element("rules.option.0").waitForExistence(timeout: 10), "No choices for How alike")
        try audit("rule-choice", tidy)
        failOnAppIssues()
    }

    /// The Rules rows with the longest words, at the largest text size: the switches, which go
    /// under their words there, and the rules with choices, whose choice wraps under the name. In strict
    /// mode, fails if a switch row isn't more than twice its default height, or the clipped text
    /// audit finds anything in a row. That audit sees only what VoiceOver
    /// sees, one switch per switch row, so a screenshot of each row shows its words; the element
    /// tree and the full audit are attached too.
    @MainActor
    func testRulesAtLargestText() throws {
        let tidy = AppDriver(self)
        tidy.launch(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
        tidy.selectTab("tab.rules", label: "Rules")
        // A failed check shouldn't stop the rest: the screenshots and the tree say why.
        continueAfterFailure = true
        let switches = ["rules.switch.screenshots", "rules.switch.recentFiles"]
        let choices = ["scope", "sensitivity", "videoMinimum", "largeFileMinimum"].map { "rules.choice.\($0)" }
        for (index, identifier) in (switches + choices).enumerated() {
            let row = tidy.element(identifier)
            guard tidy.reveal(row) else {
                XCTFail("\(identifier) never came on screen")
                continue
            }
            tidy.screenshot("rules-ax5-\(index + 1)")
            let frame = row.frame
            var clipped: [String] = []
            do {
                try tidy.app.performAccessibilityAudit(for: .textClipped) { issue in
                    if let element = issue.element, element.exists, element.frame.intersects(frame) {
                        clipped.append(Self.describe(issue))
                    }
                    return true
                }
            } catch {
                XCTFail("The clipped text audit didn't run on \(identifier): \(error)")
            }
            attach(text: "\(identifier): \(Int(frame.height)) points tall\n" + clipped.joined(separator: "\n"), named: "ax5-row-\(index + 1)")
            guard strict else { continue }
            if switches.contains(identifier) {
                XCTAssertGreaterThan(
                    frame.height, 2 * Self.defaultSwitchRowHeight,
                    "\(identifier) is \(Int(frame.height)) points tall at the largest text size: its words didn't grow"
                )
            }
            XCTAssertEqual(clipped, [], "Clipped text in \(identifier) at the largest text size")
        }
        attach(text: tidy.app.debugDescription, named: "tree-rules-ax5")
        try audit("rules-ax5", tidy)
    }

    /// A Rules switch row's height at the default text size, from the CI element tree.
    private static let defaultSwitchRowHeight: CGFloat = 52

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
        let barTop = bottomBarTop(in: tidy.app)
        var found: [String] = []
        var details: [String] = []
        var ignored: [String] = []

        // Returning true marks an issue as handled, so the audit itself never fails the test;
        // failOnAppIssues() does, with the whole list.
        try tidy.app.performAccessibilityAudit(for: .all) { issue in
            let what = Self.describe(issue)
            if let reason = Self.systemOwned(issue, chrome: chrome, barTop: barTop) {
                ignored.append("\(what) [ignored: \(reason)]")
            } else if let ratio = Self.measuredBarButtonContrast(issue), ratio >= 4.5 {
                ignored.append("\(what) [ignored: measured \(String(format: "%.1f", ratio)):1 inside the button]")
            } else {
                found.append(what)
                details.append(Self.position(of: issue) + issue.detailedDescription)
            }
            return true
        }
        appIssues += found.map { "\(screen): \($0)" }

        var note = "\(screen): \(found.count) issue(s), bottom bar at y \(barTop.map { "\(Int($0))" } ?? "none")\n"
            + zip(found, details).map { "- \($0)\n    \($1)" }.joined(separator: "\n")
        if !ignored.isEmpty {
            note += "\nIgnored:\n" + ignored.map { "- \($0)" }.joined(separator: "\n")
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

    /// The top of whatever floats at the bottom of the screen: the app's bottom bar or the tab
    /// bar, whichever is higher. Bars behind a sheet can't be tapped, and don't count.
    @MainActor
    private func bottomBarTop(in app: XCUIApplication) -> CGFloat? {
        let bars = ["actionbar.primary", "actionbar.secondary"].map { app.buttons[$0] } + [app.tabBars.firstMatch]
        return bars.filter { $0.exists && $0.isHittable }.map(\.frame.minY).min()
    }

    /// How far above the bottom bar iOS's scroll edge effect reaches. On the CI screenshots it
    /// starts about 55 points above the bar's buttons, and the audit reports text 38 points
    /// above them as low contrast.
    private static let edgeFade: CGFloat = 60

    /// Why an issue is iOS's rather than the app's, or nil if it's the app's to fix.
    ///
    /// Only elements with no accessibility identifier can be iOS's: every control Tidykeep
    /// draws for its own screens carries one (see the UI-test contract). Of those, an issue
    /// with no element at all, or on an element inside a navigation bar, the tab bar, a
    /// toolbar, the status bar, the keyboard or an alert, is in UIKit's chrome: the back
    /// button, the large title, the tab bar's own buttons. The app can't change how those
    /// are drawn, so failing on them would only hide its own issues behind noise.
    ///
    /// Two narrower exceptions cover elements with identifiers too. Bar buttons in the tab bar
    /// and the navigation bar are drawn by iOS at a fixed size, using the Large Content Viewer
    /// instead of Dynamic Type, which the audit reports as a Dynamic Type issue. And content
    /// scrolled under the app's bottom bar or the tab bar is faded on purpose by iOS's scroll
    /// edge effect, which starts about 55 points above them; it can be scrolled up to be read. So
    /// contrast there is let go, except on the bars' own buttons, which are measured instead
    /// (`measuredBarButtonContrast`).
    ///
    /// An element that has gone by the time the issue is looked at counts as the app's: it
    /// can't be shown to be iOS's.
    @MainActor
    private static func systemOwned(_ issue: XCUIAccessibilityAuditIssue, chrome: [CGRect], barTop: CGFloat?) -> String? {
        guard let element = issue.element else { return "no element: drawn outside the app's views" }
        guard element.exists else { return nil }
        let identifier = element.identifier
        let frame = element.frame
        let inChrome = chrome.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        if issue.auditType == .dynamicType && inChrome {
            return "bar button, sized by iOS"
        }
        if issue.auditType == .contrast, let barTop, frame.midY > barTop - edgeFade,
           !inChrome, !identifier.hasPrefix("actionbar.") {
            return frame.midY > barTop ? "scrolled under the bottom bar" : "faded by iOS above the bottom bar"
        }
        if identifier.isEmpty && inChrome {
            return "system bar or alert"
        }
        return nil
    }

    /// For a bar button that failed contrast, the contrast measured from its own screenshot, or nil.
    ///
    /// When photos scroll up behind a bar button, the audit fails it even though its label sits
    /// on an opaque capsule: 6.5:1 measured this way on the CI screenshot of the group screen, where the
    /// same button over a plain background passes. So the ratio is measured over the middle
    /// of the capsule, away from its corners: between the median colour (the fill) and the
    /// darkest or lightest one (the label), by the WCAG formula.
    @MainActor
    private static func measuredBarButtonContrast(_ issue: XCUIAccessibilityAuditIssue) -> Double? {
        guard issue.auditType == .contrast, let element = issue.element, element.exists,
              element.identifier.hasPrefix("actionbar."),
              let image = element.screenshot().image.cgImage else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        func linear(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var luminances: [Double] = []
        for y in (height * 3 / 10)..<(height * 7 / 10) {
            for x in (width * 15 / 100)..<(width * 85 / 100) {
                let i = (y * width + x) * 4
                luminances.append(0.2126 * linear(pixels[i]) + 0.7152 * linear(pixels[i + 1]) + 0.0722 * linear(pixels[i + 2]))
            }
        }
        guard luminances.count > 100 else { return nil }
        luminances.sort()
        func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        let fill = luminances[luminances.count / 2]
        let darkest = luminances[luminances.count / 100], lightest = luminances[luminances.count * 99 / 100]
        return max(ratio(fill, darkest), ratio(fill, lightest))
    }

    /// The element's frame, to tell where on screen an issue is.
    @MainActor
    private static func position(of issue: XCUIAccessibilityAuditIssue) -> String {
        guard let element = issue.element, element.exists else { return "" }
        let f = element.frame
        return "at y \(Int(f.minY))-\(Int(f.maxY)): "
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
