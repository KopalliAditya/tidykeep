import SwiftUI
import TidykeepCore
import TidykeepFiles
import UniformTypeIdentifiers

// Pieces the Files screens share: the folder picker, the status header, the no-folders state,
// file rows and the coverage sheet.

// MARK: - Folder picker

extension View {
    /// The system folder picker. Picked folders are remembered and checked straight away.
    /// With `replacing`, it's choosing again a folder that couldn't be opened: one folder,
    /// which takes that folder's place.
    func folderPicker(isPresented: Binding<Bool>, replacing: UUID? = nil) -> some View {
        modifier(FolderPicker(isPresented: isPresented, replacing: replacing))
    }
}

private struct FolderPicker: ViewModifier {
    @Environment(FilesModel.self) private var files
    @Binding var isPresented: Bool
    let replacing: UUID?

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder], allowsMultipleSelection: replacing == nil) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                files.addFolders(urls, replacing: replacing)
            }
        }
    }
}

// MARK: - Layout

/// A row that lays its parts side by side, and stacks them at accessibility text sizes so
/// nothing is cut off.
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat = Space.m
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: spacing))
        layout { content }
    }
}

/// The symbol for a file, from its extension.
enum FileSymbol {
    static func name(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// A file's symbol in a tinted tile, like the Home rows.
struct FileTile: View {
    let name: String
    var tint: Color = Palette.accent

    var body: some View {
        Image(systemName: FileSymbol.name(for: name))
            .font(.body.weight(.medium))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Status

/// Where the folder check is ("1,204 of 2,814 checked"), or what it found, with the coverage
/// line that opens what was left out.
struct FilesStatusHeader: View {
    let summary: String
    @Environment(FilesModel.self) private var files
    @ViewState private var showsCoverage = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let progress = progressText {
                HStack(spacing: Space.s) {
                    Text(progress)
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    ProgressView().controlSize(.small)
                }
                .accessibilityElement(children: .combine)
                if case .comparing(let checked, let total) = files.phase, total > 0 {
                    ProgressView(value: Double(checked), total: Double(total))
                        .tint(Palette.accent)
                        .accessibilityHidden(true)
                }
            } else {
                Text(summary)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // With no folder opened there's nothing to account for; the note below says why.
            if files.hasChecked, files.checkedFolderCount > 0 {
                Button { showsCoverage = true } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(Palette.accent)
                            .accessibilityHidden(true)
                        Text(coverageLine)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                        Image(systemName: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(coverageLine)
                .accessibilityHint(Copy.Files.coverageHint)
                .accessibilityIdentifier("files.coverage")
            }
        }
        .padding(.vertical, Space.xs)
        .sheet(isPresented: $showsCoverage) { FilesCoverageSheet() }
    }

    private var coverageLine: String {
        Copy.Files.coverage(checked: files.checkedCount, skipped: files.skippedCount)
    }

    private var progressText: String? {
        switch files.phase {
        case .idle: nil
        case .listing(let found): found == 0 ? Copy.Files.gettingReady : Copy.Files.listing(found)
        case .comparing(let checked, let total): Copy.Files.progress(checked: checked, total: total)
        }
    }
}

/// What the last folder check looked at and what it left out.
struct FilesCoverageSheet: View {
    @Environment(FilesModel.self) private var files
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(Copy.Files.coverageChecked(files.checkedCount)) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Palette.accent)
                            .accessibilityHidden(true)
                    }
                }
                Section {
                    ForEach(FileSkipReason.allCases, id: \.self) { reason in
                        row(Copy.Files.skipReason(reason), count: files.skipped[reason] ?? 0, detail: Copy.Files.skipExplanation(reason))
                    }
                    row(Copy.Files.keptByRule, count: files.keptByRule, detail: Copy.Files.keptByRuleExplanation(days: files.recentDays))
                } footer: {
                    Text(Copy.Files.coverageFooter)
                }
            }
            .groupedList()
            .navigationTitle(Copy.Files.coverageTitle)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.General.done) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, count: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            LabeledContent(title) {
                Text(count.formatted()).monospacedDigit()
            }
            .font(.body.weight(.medium))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Space.hair)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - States

/// No folders yet: what choosing one does, and the button that opens the picker.
struct NoFoldersView: View {
    let choose: () -> Void

    var body: some View {
        VStack(spacing: Space.l) {
            Image(systemName: "folder.badge.plus")
                .font(.system(.largeTitle, design: .default).weight(.light))
                .imageScale(.large)
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            VStack(spacing: Space.s) {
                Text(Copy.Files.noFoldersTitle)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(Copy.Files.noFoldersDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: choose) {
                Text(Copy.Files.chooseFolders)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(minWidth: 180, minHeight: 30)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .controlSize(.large)
            .accessibilityHint(Copy.Files.chooseFoldersHint)
            .accessibilityIdentifier("files.chooseFolders")
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// Folders that couldn't be opened, each with a way to choose it again.
struct UnavailableFoldersNote: View {
    let folders: [FilesModel.Folder]
    let chooseAgain: (FilesModel.Folder) -> Void

    var body: some View {
        ForEach(folders) { folder in
            InlineError(text: Copy.Files.unavailableNote(folder.name)) { chooseAgain(folder) }
        }
    }
}

// MARK: - Rows

/// One copy of a file: name, where it is, its exact size and when it last changed.
struct FileDetails: View {
    let name: String
    let location: String
    let bytes: Int64
    let date: String
    var badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            Text(name)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(location)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(Copy.bytes(bytes)) · \(date)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if let badge {
                Label(badge, systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .padding(.top, Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
