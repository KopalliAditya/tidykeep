import Foundation
import SwiftUI
import Testing
import TidykeepCore
import TidykeepFiles
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

        let review = HoldingView.deleteRequest(files.held, in: files)
        // The sheet's own NavigationStack doesn't draw inside the harness's, so draw its words.
        let reviewBody = ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text(review.title).font(.title2.weight(.bold))
                ReasonCard(reason: review.reason)
                ReasonCard(reason: HoldingView.deleteRequest(files.held, in: files, iCloud: true).reason)
            }
            .padding(Space.l)
        }
        await RenderHarness.render(reviewBody, named: "holding-review", state: state, height: 900)

        await files.putAllBack()
        #expect(files.holdingCount == 0)

        // A held file whose folder was deleted, waiting for the user to choose a place.
        let gone = try await folderGoneModel(state)
        #expect(gone.needsPlace.count == 1)
        await RenderHarness.render(HoldingView().environment(gone), named: "holding-folder-gone", state: state)

        // The only chosen folder can't be opened: no "All tidy".
        let unopenable = await unopenableModel(state)
        #expect(!unopenable.canSayAllTidy)
        await RenderHarness.render(DuplicateFilesView().environment(unopenable), named: "dupfiles-unavailable", state: state)
        await RenderHarness.render(LargeFilesView().environment(unopenable), named: "largefiles-unavailable", state: state)
    }

    private func folderGoneModel(_ state: AppState) async throws -> FilesModel {
        let folder = temporaryDirectory("render-gone-\(UUID().uuidString)")
            .appendingPathComponent("Downloads", isDirectory: true)
        let trips = folder.appendingPathComponent("Trips", isDirectory: true)
        try FileManager.default.createDirectory(at: trips, withIntermediateDirectories: true)
        let content = Data((0..<48_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let old = Date().addingTimeInterval(-40 * 86_400)
        for name in ["Boarding pass.pdf", "Boarding pass (1).pdf"] {
            let url = trips.appendingPathComponent(name)
            try content.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: url.path)
        }
        let model = FilesModel(directory: nil, preferences: state.preferences, history: History(directory: nil), notices: Notices())
        await model.start()
        model.addFolder(folder)
        await model.scanned()
        #expect(await model.moveToHolding(try #require(model.duplicateGroups.first)))
        try FileManager.default.removeItem(at: trips)
        await model.putAllBack()
        return model
    }

    private func unopenableModel(_ state: AppState) async -> FilesModel {
        let data = temporaryDirectory("render-unopenable-\(UUID().uuidString)")
        try? JSONFile<[FolderRef]>(url: data.appendingPathComponent("folders.json"))
            .save([FolderRef(displayName: "Downloads", bookmark: Data("gone".utf8))])
        let model = FilesModel(directory: data, preferences: state.preferences, history: History(directory: nil), notices: Notices())
        await model.start()
        await model.scanned()
        return model
    }

    private var foldersList: some View {
        List { FoldersSection() }
            .groupedList()
            .navigationTitle(Copy.Tabs.rules)
    }
}
