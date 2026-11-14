import Foundation
import SwiftUI
import Testing
import TidykeepCore
import TidykeepTestSupport
@testable import TidykeepUI

/// Draws the Files screens for design review, from the demo library plus the sample folder
/// written to a temporary directory.
///
///     TK_RENDER_DIR=/tmp/renders bash scripts/test.sh --filter FilesRenders
@MainActor @Suite(.serialized) struct FilesRenders {
    @Test func filesScreens() async throws {
        let state = try await RenderHarness.demoState()
        let files = state.files

        // Before any folder is chosen.
        await RenderHarness.render(DuplicateFilesView(), named: "files-no-folders", state: state)
        await RenderHarness.render(HoldingView(), named: "holding-empty", state: state)
        await RenderHarness.render(foldersList, named: "folders-empty", state: state, height: 420)

        // The sample folder, checked.
        let documents = temporaryDirectory("render-docs-\(UUID().uuidString)")
        files.seedSample(in: documents)
        await files.scanned()
        #expect(files.duplicateSetCount == 1)
        #expect(files.largeFileCount == 1)

        await RenderHarness.render(TidyHomeView(), named: "home-files", state: state, height: 1500)
        await RenderHarness.render(DuplicateFilesView(), named: "dupfiles", state: state)
        let group = try #require(files.duplicateGroups.first)
        await RenderHarness.render(DuplicateFileSetView(setID: group.id), named: "dupfileset", state: state, height: 1250)
        await RenderHarness.render(LargeFilesView(), named: "largefiles", state: state)
        await RenderHarness.render(foldersList, named: "folders", state: state, height: 420)
        await RenderHarness.render(FilesCoverageSheet(), named: "files-coverage", state: state)

        // Both moved to Holding.
        #expect(await files.moveToHolding(group))
        let export = try #require(files.largeFiles.first)
        #expect(await files.moveToHolding([export]))
        #expect(files.holdingCount == 2)
        await RenderHarness.render(DuplicateFileSetView(setID: group.id), named: "dupfileset-gone", state: state)
        await RenderHarness.render(HoldingView(), named: "holding", state: state)
        await RenderHarness.render(DuplicateFilesView(), named: "dupfiles-tidy", state: state)

        await files.putAllBack()
        #expect(files.holdingCount == 0)
    }

    private var foldersList: some View {
        List { FoldersSection() }
            .groupedList()
            .navigationTitle(Copy.Tabs.rules)
    }
}
