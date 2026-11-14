import Contacts
import Foundation
import Photos
import Synchronization
import Testing

// What the app-hosted tests can count on, read from the environment CI sets up.
//
// These tests run inside Tidykeep on a simulator, with the access CI granted beforehand
// (`xcrun simctl privacy grant`), against the photos scripts/ci/seed-simulator.sh added.
// scripts/ci/run-tests.sh passes every TK_* variable through to the test process:
//   TK_SEED_PHOTOS, TK_SEED_SCREENSHOTS, TK_SEED_VIDEOS, TK_SEED_BURSTS  how many were seeded
//   TK_SEED_FIRST, TK_SEED_LAST    ISO 8601 capture dates of the oldest and newest
//   TK_REQUIRE_ACCESS=1            fail, rather than skip, when access or the seed is missing
//
// Nothing here touches a real device's library or address book: every suite that reads
// either is compiled for the simulator only.
enum TestEnvironment {
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    static func value(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return value
    }

    static func number(_ name: String) -> Int? { value(name).flatMap { Int($0) } }

    static var seedPhotos: Int? { number("TK_SEED_PHOTOS") }
    static var seedScreenshots: Int? { number("TK_SEED_SCREENSHOTS") }
    static var seedVideos: Int? { number("TK_SEED_VIDEOS") }
    static var seedBursts: Int? { number("TK_SEED_BURSTS") }
    static var requiresAccess: Bool { value("TK_REQUIRE_ACCESS") == "1" }

    /// The seeded capture dates, widened by a day and a bit each way: EXIF dates carry no
    /// time zone, so Photos reads them in the simulator's.
    static var seedRange: ClosedRange<Date>? {
        let iso = ISO8601DateFormatter()
        guard let first = value("TK_SEED_FIRST").flatMap(iso.date(from:)),
              let last = value("TK_SEED_LAST").flatMap(iso.date(from:)),
              first <= last
        else { return nil }
        let slack: TimeInterval = 26 * 60 * 60
        return first.addingTimeInterval(-slack)...last.addingTimeInterval(slack)
    }

    /// The UI tests run first and really remove photos: the extra shots of one burst and
    /// the extra copies of one set, a few more if a run was retried.
    static let removedByUITestsAtMost = 12

    static var photosAuthorized: Bool {
        isSimulator && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// The app declares why it reads contacts; without it iOS would end the process.
    static var contactsDeclared: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil
    }

    static var contactsAuthorized: Bool {
        isSimulator && contactsDeclared && CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }
}

/// A value set from a `@Sendable` closure (PhotoKit's change block) and read afterwards.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }
}

#if targetEnvironment(simulator)
/// On CI a missing grant or seed must fail, not quietly skip every test that needs it.
@Suite("CI set the simulator up", .enabled(if: TestEnvironment.requiresAccess))
struct CIPreconditionTests {
    @Test func photoAccessWasGranted() {
        #expect(TestEnvironment.photosAuthorized, "xcrun simctl privacy grant photos didn't take")
    }

    @Test func contactsAccessWasGranted() {
        #expect(TestEnvironment.contactsDeclared, "No NSContactsUsageDescription in the app's Info.plist")
        #expect(TestEnvironment.contactsAuthorized, "xcrun simctl privacy grant contacts didn't take")
    }

    @Test func theSeedIsDescribed() {
        #expect(TestEnvironment.seedPhotos != nil, "TK_SEED_PHOTOS not passed to the tests")
        #expect(TestEnvironment.seedRange != nil, "TK_SEED_FIRST and TK_SEED_LAST not passed to the tests")
    }
}
#endif
