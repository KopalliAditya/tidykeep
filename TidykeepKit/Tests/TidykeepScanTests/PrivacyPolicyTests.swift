import Foundation
import Testing
@testable import TidykeepUI

/// The policy the app shows is `docs/PRIVACY.md` as plain text, so the two never say
/// different things.
@MainActor @Suite struct PrivacyPolicyTests {
    /// Each paragraph of the Markdown, without `#` headings and `**`, joined onto one line, is
    /// the same paragraph in PrivacyPolicy.txt.
    @Test func theAppShowsTheSamePolicyAsTheDocs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TidykeepScanTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // TidykeepKit
            .deletingLastPathComponent()
        let markdown = try String(contentsOf: root.appendingPathComponent("docs/PRIVACY.md"), encoding: .utf8)
        let paragraphs = markdown.trimmingCharacters(in: .newlines).components(separatedBy: "\n\n").map { paragraph in
            let text = paragraph.hasPrefix("#") ? String(paragraph.drop { $0 == "#" }.dropFirst()) : paragraph
            return text.components(separatedBy: "\n").joined(separator: " ").replacingOccurrences(of: "**", with: "")
        }
        let shipped = TextDocumentView.load("PrivacyPolicy").trimmingCharacters(in: .newlines).components(separatedBy: "\n\n")
        #expect(paragraphs.count == shipped.count)
        for (docs, app) in zip(paragraphs, shipped) {
            #expect(docs == app)
        }
    }
}
