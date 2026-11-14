import XCTest

// Shared by the UI tests: launching Tidykeep in a known state, finding its elements by
// accessibility identifier, moving around, and answering the system prompts.
//
// Every test launches with -TKResetState YES (a fresh install as far as the app's own data
// goes) plus only the seeds it needs. The photo library is the simulator's, seeded by CI
// with scripts/ci/seed-simulator.sh, and the app's photo and contacts access is granted
// beforehand with `xcrun simctl privacy`, except for PermissionUITests, which CI runs last
// with that access reset so it can turn it down. Labels are matched in English: the scheme
// runs the tests with language en, region US, and the launch arguments below say the same.

/// The system prompts Tidykeep runs into, answered the way a person would.
///
/// iOS shows these outside the app's own views. The access prompts belong to SpringBoard;
/// the prompt PhotoKit shows before deleting or changing photos has been seen under
/// SpringBoard and as an alert inside the app, so both are searched. Only alerts and
/// action sheets are searched, never the app's own buttons: Tidykeep has a "Delete now"
/// and a "Merge" of its own, and tapping those by mistake would hide a real failure.
@MainActor
enum SystemAlerts {
    static let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// The photo access prompt, if the pre-granted access didn't stick.
    static let photoAccess = ["Allow Full Access", "Allow Access to All Photos"]

    /// Turning down the photo or contacts prompt. iOS writes it with a curly apostrophe;
    /// the straight one is in case a runtime doesn't.
    static let denyAccess = ["Don\u{2019}t Allow", "Don't Allow"]

    /// PhotoKit asks before moving photos to Recently Deleted.
    static let confirmDelete = ["Delete"]

    /// PhotoKit asks before deleting, and before changing a photo it keeps.
    static let confirmPhotoChange = ["Delete", "Modify", "Allow"]

    /// The contacts access prompt (iOS 18 and later asks in two steps).
    static let contactsAccess = NSPredicate(
        format: "label IN %@ OR label BEGINSWITH 'Share All'",
        ["Allow Full Access", "Continue", "Allow"]
    )

    /// Waits for a system alert button with one of `labels` and taps it. Returns the label
    /// tapped, or nil if none came within `timeout`.
    @discardableResult
    static func tap(_ labels: [String], in app: XCUIApplication, timeout: TimeInterval) -> String? {
        tap(matching: NSPredicate(format: "label IN %@", labels), in: app, timeout: timeout)
    }

    @discardableResult
    static func tap(matching predicate: NSPredicate, in app: XCUIApplication, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let candidates = [
                springboard.alerts.buttons.matching(predicate).firstMatch,
                app.alerts.buttons.matching(predicate).firstMatch,
                app.sheets.buttons.matching(predicate).firstMatch,
                springboard.sheets.buttons.matching(predicate).firstMatch,
            ]
            for candidate in candidates where candidate.exists && candidate.isHittable {
                let label = candidate.label
                candidate.tap()
                return label
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return nil
    }

    /// Text of whatever alert is showing, for failure messages.
    static func describeVisibleAlert(in app: XCUIApplication) -> String {
        for (name, host) in [("SpringBoard", springboard), ("app", app)] {
            let alert = host.alerts.firstMatch
            if alert.exists {
                let buttons = alert.buttons.allElementsBoundByIndex.map(\.label)
                return "\(name) alert \"\(alert.label)\" with buttons \(buttons)"
            }
        }
        return "no alert visible"
    }
}

/// Seeds a test asks the app to make for itself (simulator only, see AppState).
struct Seeds: OptionSet {
    let rawValue: Int
    /// Documents/Tidykeep Sample: two byte-identical PDFs, a small file and a 120 MB video.
    static let files = Seeds(rawValue: 1 << 0)
    /// Two "Jordan Rivera" cards with the same mobile number.
    static let contacts = Seeds(rawValue: 1 << 1)
}

/// Drives the app. One per test.
@MainActor
final class AppDriver {
    let app = XCUIApplication()
    private unowned let test: XCTestCase
    /// Screens pushed on the current tab's navigation stack by `open(_:)`.
    private(set) var depth = 0

    init(_ test: XCTestCase) {
        self.test = test
    }

    // MARK: Launching

    /// Launches a fresh copy of the app, then gets past onboarding to the Tidy tab.
    /// `appearance` ("dark" or "light") forces the app's look through -TKAppearance, for
    /// when XCUIDevice can't switch the simulator's. `textSize` is a UIKit content size category
    /// name, such as "UICTContentSizeCategoryAccessibilityXXXL", for the app's text size.
    ///
    /// By default the photo prompt, if it shows, is allowed, and the Tidy tab counts once its
    /// coverage line shows. A test that answers the prompt itself passes
    /// `answeringPhotoPrompt: false` and a `marker` the tab shows without photo access, such
    /// as "home.row.dupfiles"; the prompt may then still be up when this returns.
    func launch(
        seeds: Seeds = [], appearance: String? = nil, textSize: String? = nil,
        answeringPhotoPrompt: Bool = true, marker: String = "coverage.line",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var arguments = [
            "-TKResetState", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if seeds.contains(.files) { arguments += ["-TKSeedFiles", "YES"] }
        if seeds.contains(.contacts) { arguments += ["-TKSeedContacts", "YES"] }
        if let appearance { arguments += ["-TKAppearance", appearance] }
        if let textSize { arguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launchArguments = arguments
        app.launch()
        depth = 0

        // Onboarding first, then possibly the photo prompt if the pre-granted access didn't
        // stick, then the Tidy tab. Poll for all three rather than assuming an order. The
        // Tidy tab counts only once onboarding has come and gone: it can show for a moment
        // before the onboarding cover does. If onboarding never shows, the wait still ends
        // after a while so the failure below says why.
        let proceed = element("onboarding.continue")
        let arrival = element(marker)
        let launched = Date()
        var sawOnboarding = false
        let arrived = until(60) {
            if proceed.exists {
                sawOnboarding = true
                if proceed.isHittable && proceed.isEnabled { proceed.tap() }
                return false
            }
            if answeringPhotoPrompt {
                SystemAlerts.tap(SystemAlerts.photoAccess, in: self.app, timeout: 0)
            }
            return arrival.exists && (sawOnboarding || Date().timeIntervalSince(launched) > 20)
        }
        // A fresh install always starts with onboarding. Without it, -TKResetState no longer
        // resets, and every test would run on whatever the last one left behind.
        XCTAssertTrue(
            sawOnboarding,
            "No onboarding after -TKResetState YES: the app didn't start as a fresh install",
            file: file, line: line
        )
        XCTAssertTrue(
            arrived,
            "The Tidy tab didn't show after onboarding (\(SystemAlerts.describeVisibleAlert(in: app)))",
            file: file, line: line
        )
    }

    /// Waits for the photo check to finish. The coverage line shows from the moment a check
    /// starts ("Checked 0 photos"), so it isn't enough: the check is done once the progress
    /// line ("scan.status") has gone and neither photo card still says "Checking…" (copies
    /// can finish after the similar shots).
    @discardableResult
    func waitForPhotoCheck(timeout: TimeInterval = 180, file: StaticString = #filePath, line: UInt = #line) -> String {
        let coverage = element("coverage.line")
        let status = element("scan.status")
        let cards = [element("home.card.similar"), element("home.card.copies")]
        let done = until(timeout, every: 2) {
            coverage.exists && !status.exists
                && cards.allSatisfy { $0.exists && !$0.label.contains("Checking") }
        }
        let label = coverage.exists ? coverage.label : "(no coverage line)"
        XCTAssertTrue(done, "The photo check didn't finish in \(Int(timeout))s: \(label)", file: file, line: line)
        return label
    }

    // MARK: Finding

    /// The app's element with this accessibility identifier, whatever kind it is.
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Elements whose identifier starts with `prefix`, like "history.row.".
    func elements(prefixed prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    /// How many different rows start with `prefix`. SwiftUI can hand a row's identifier
    /// down to the views inside it, so elements are counted by identifier, not one by one.
    func rowCount(prefixed prefix: String) -> Int {
        Set(elements(prefixed: prefix).allElementsBoundByIndex.map(\.identifier)).count
    }

    /// The "All tidy" empty state. Its symbol and text are one accessibility element with no
    /// identifier, so it's found by its label ("All tidy", then any detail), or by
    /// "empty.alltidy" if the app ever gives it that identifier.
    func allTidy() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'empty.alltidy' OR label BEGINSWITH 'All tidy'"))
            .firstMatch
    }

    /// The first app button with exactly this label that isn't at `frame`. Finds the button
    /// in a confirmation dialog that repeats the label of the button that opened it.
    func dialogButton(_ label: String, notAt frame: CGRect? = nil, timeout: TimeInterval) -> XCUIElement? {
        var found: XCUIElement?
        until(timeout) {
            let buttons = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            found = buttons.first { button in
                guard button.exists && button.isHittable else { return false }
                guard let frame else { return true }
                return !button.frame.equalTo(frame)
            }
            return found != nil
        }
        return found
    }

    /// Polls `condition` until it holds or `timeout` passes.
    @discardableResult
    func until(_ timeout: TimeInterval, every interval: TimeInterval = 0.5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        } while Date() < deadline
        return condition()
    }

    // MARK: Moving around

    /// Taps the element, scrolling to it first. Fails the test if it never appears.
    func tap(_ identifier: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(identifier)
        guard reveal(target, isContent: Self.isContent(identifier), timeout: timeout) else {
            XCTFail("No \(identifier) on screen within \(Int(timeout))s", file: file, line: line)
            return
        }
        if target.isHittable {
            target.tap()
        } else {
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// Taps something that pushes a screen (a card, a row), so `popToRoot` can come back.
    func open(_ identifier: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        tap(identifier, timeout: timeout, file: file, line: line)
        depth += 1
    }

    /// Rows and cards scroll under the floating bars; buttons in the bars don't.
    private static func isContent(_ identifier: String) -> Bool {
        identifier.contains(".row.") || identifier.contains(".tile.") || identifier.hasPrefix("home.")
            || identifier.hasPrefix("rules.keep.") || identifier.hasPrefix("rules.choice.")
            || identifier.hasPrefix("rules.option.")
    }

    /// Scrolls until `target` is on screen and clear of the bottom bars. Lists load rows
    /// lazily, so a row further down may not exist until the list scrolls toward it: this
    /// scrolls down a few steps, then back up, until the time runs out.
    @discardableResult
    func reveal(_ target: XCUIElement, isContent: Bool = true, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        // The screen may still be loading; give it a moment before scrolling it.
        _ = target.waitForExistence(timeout: min(5, timeout))
        var steps = 0
        var towardEnd = true
        while Date() < deadline {
            if target.exists && target.isHittable && (!isContent || isClearOfBars(target)) {
                return true
            }
            if steps == 6 {
                towardEnd.toggle()
                steps = 0
            }
            scroll(towardEnd: target.exists ? isBelowBars(target) : towardEnd)
            steps += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        return target.exists
    }

    /// The top of whatever floats over the bottom of the content: the action bar or the
    /// tab bar, whichever is higher.
    private func barsTop() -> CGFloat {
        var top = app.windows.firstMatch.frame.maxY
        for bar in [element("actionbar.primary"), element("actionbar.secondary"), app.tabBars.firstMatch]
        where bar.exists && !bar.frame.isEmpty {
            top = min(top, bar.frame.minY - 8)
        }
        return top
    }

    private func isClearOfBars(_ target: XCUIElement) -> Bool {
        target.frame.midY < barsTop()
    }

    private func isBelowBars(_ target: XCUIElement) -> Bool {
        target.frame.midY >= barsTop()
    }

    /// One short drag. Toward the end moves the content up to show what's below.
    func scroll(towardEnd: Bool) {
        let window = app.windows.firstMatch
        let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68))
        let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38))
        if towardEnd {
            low.press(forDuration: 0.05, thenDragTo: high)
        } else {
            high.press(forDuration: 0.05, thenDragTo: low)
        }
    }

    /// Goes back one screen.
    func back() {
        let system = app.navigationBars.buttons.matching(identifier: "BackButton").allElementsBoundByIndex
        let labelled = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Back'")).allElementsBoundByIndex
        if let button = (system + labelled).first(where: { $0.exists && $0.isHittable }) {
            button.tap()
        } else {
            // The edge swipe a person would use. Harmless on a top screen, unlike tapping
            // whatever button a navigation bar happens to show first.
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
        depth = max(0, depth - 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    /// Things only the Tidy tab's top screen shows.
    static let homeMarkers = [
        "coverage.line", "home.card.similar", "home.row.dupfiles", "home.row.holding", "home.row.contacts",
    ]

    /// Back to the top of the current tab. Stops early if the app went back by itself.
    func popToRoot(markers: [String] = AppDriver.homeMarkers) {
        var guardSteps = depth + 2
        while depth > 0 && guardSteps > 0 {
            if markers.contains(where: { element($0).exists && element($0).isHittable }) {
                depth = 0
                break
            }
            back()
            guardSteps -= 1
        }
        depth = 0
    }

    /// Selects a tab: its tab bar button by identifier, then by label, then anything with
    /// the identifier. The identifier is set on the `Tab`, and SwiftUI may put it on the
    /// tab's content rather than its button, so only a candidate that can be tapped is used.
    func selectTab(_ identifier: String, label: String, file: StaticString = #filePath, line: UInt = #line) {
        let candidates = [app.tabBars.buttons[identifier], app.tabBars.buttons[label], element(identifier)]
        var found: XCUIElement?
        var nudges = 0
        until(15) {
            found = candidates.first { $0.exists && $0.isHittable }
            if found != nil { return true }
            if nudges < 3 {
                // A minimized tab bar comes back when the content scrolls toward the top. A
                // short drag, so a list already at the top doesn't pull to refresh.
                nudges += 1
                let window = app.windows.firstMatch
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53)))
            }
            return false
        }
        guard let button = found else {
            let seen = candidates.map { $0.exists ? ($0.isHittable ? "tappable" : "not tappable") : "missing" }
            XCTFail(
                "No \(label) tab to tap. Tab bar button by identifier, by label, any element: \(seen.joined(separator: ", "))",
                file: file, line: line
            )
            return
        }
        button.tap()
        depth = 0
    }

    // MARK: Checking

    /// Waits for the notice banner and returns its text. Fails if none shows. The banner
    /// goes away by itself after a few seconds, so call this straight after the action.
    @discardableResult
    func waitForNotice(timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) -> String {
        let banner = element("notice.banner")
        var label = ""
        let shown = until(timeout, every: 0.25) {
            guard banner.exists else { return false }
            label = banner.label
            return true
        }
        XCTAssertTrue(shown, "No notice banner", file: file, line: line)
        return label
    }

    /// Answers PhotoKit's prompts one after another (a merge can ask to delete the extra
    /// copies and to change the one it keeps) until the app's notice shows. Returns the
    /// labels tapped, in order, and the notice text if it came within `settle` seconds of
    /// the first prompt. Reading the notice here matters: it goes away after six seconds.
    func confirmPhotoPrompts(first: TimeInterval = 30, settle: TimeInterval = 20) -> (prompts: [String], notice: String?) {
        guard let label = SystemAlerts.tap(SystemAlerts.confirmPhotoChange, in: app, timeout: first) else {
            return ([], nil)
        }
        var prompts = [label]
        let banner = element("notice.banner")
        var notice: String?
        until(settle, every: 0.25) {
            if banner.exists {
                notice = banner.label
                return true
            }
            if prompts.count < 4, let next = SystemAlerts.tap(SystemAlerts.confirmPhotoChange, in: app, timeout: 0) {
                prompts.append(next)
            }
            return false
        }
        return (prompts, notice)
    }

    /// Whether the notice offers Undo: as its own button, or as part of the banner's
    /// combined label.
    func noticeOffersUndo(_ label: String) -> Bool {
        label.localizedCaseInsensitiveContains("Undo") || undoButton() != nil
    }

    /// The notice banner's Undo, if XCUITest can see it as a button.
    func undoButton() -> XCUIElement? {
        let candidates = [
            element("notice.undo"),
            element("notice.banner").buttons["Undo"],
            app.buttons.matching(NSPredicate(format: "label == 'Undo'")).firstMatch,
        ]
        return candidates.first { $0.exists && $0.isHittable }
    }

    /// The Review sheet's title ("Remove 9 photos?", "Merge 3 copies?"), once the sheet
    /// shows. The contract only promises review.confirm and the title's first word, so the
    /// title is found by its identifier when the app gives it one ("review.title"), else by
    /// its text.
    func reviewTitle(timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> String {
        let confirm = element("review.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout), "No Review sheet", file: file, line: line)
        let titled = NSPredicate(format: "label BEGINSWITH 'Remove ' OR label BEGINSWITH 'Merge '")
        var title = ""
        until(5) {
            let candidates = [
                element("review.title"),
                app.navigationBars.staticTexts.matching(titled).firstMatch,
                app.staticTexts.matching(titled).firstMatch,
                app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH 'Remove ' OR identifier BEGINSWITH 'Merge '")).firstMatch,
            ]
            guard let hit = candidates.first(where: { $0.exists }) else { return false }
            title = hit.label.isEmpty ? hit.identifier : hit.label
            return true
        }
        return title
    }

    /// Closes the Review sheet without doing anything.
    func cancelReview() {
        let buttons = [element("review.cancel"), app.buttons["Cancel"], app.buttons["Close"]]
        if let button = buttons.first(where: { $0.exists && $0.isHittable }) {
            button.tap()
        } else {
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        until(10) { !self.element("review.confirm").exists }
    }

    /// Gets past the contacts pre-permission screen and the system prompt, if either
    /// shows, and waits for the merge list (or its empty state).
    func passContactsPermission(timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let proceed = element("contacts.continue")
        let firstRow = element("contacts.row.0")
        let empty = allTidy()
        var tappedContinue = false
        let arrived = until(timeout) {
            if firstRow.exists || empty.exists { return true }
            if !tappedContinue && proceed.exists && proceed.isHittable {
                proceed.tap()
                tappedContinue = true
                return false
            }
            // Access was granted beforehand; answer the prompt (both steps) if it shows.
            SystemAlerts.tap(matching: SystemAlerts.contactsAccess, in: self.app, timeout: 0)
            return false
        }
        XCTAssertTrue(
            arrived,
            "Contacts never got past permission (\(SystemAlerts.describeVisibleAlert(in: app)))",
            file: file, line: line
        )
    }

    // MARK: Attachments

    /// Keeps a screenshot of the whole screen in the result bundle, even when the test passes.
    func screenshot(_ name: String) {
        // Let animations and the glass settle.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        test.attach(XCUIScreen.main.screenshot(), named: name)
    }
}

extension XCTestCase {
    /// Keeps a screenshot in the result bundle even when the test passes.
    @MainActor
    func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot, quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Keeps a short text note in the result bundle, for CI to read back.
    @MainActor
    func attach(text: String, named name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
