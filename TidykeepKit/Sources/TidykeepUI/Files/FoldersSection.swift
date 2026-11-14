import SwiftUI
import TidykeepCore

/// The Folders section of Rules: the folders Tidykeep checks, whether each one still opens, a
/// way to stop checking one, and the button that adds more. Place it inside a `List`.
struct FoldersSection: View {
    @Environment(FilesModel.self) private var files
    @ViewState private var picking = false
    /// The folder being chosen again, or nil when adding one.
    @ViewState private var choosingAgain: UUID?
    /// An unopenable folder with held files, waiting for the user to say what to do.
    @ViewState private var confirmingRemove: FilesModel.Folder?

    var body: some View {
        Section {
            if files.folders.isEmpty {
                Text(Copy.Files.noFoldersYet)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            }
            ForEach(Array(files.folders.enumerated()), id: \.element.id) { index, folder in
                FolderRow(folder: folder, chooseAgain: { choose(replacing: folder.id) })
                    .swipeActions(edge: .trailing) {
                        Button(Copy.Files.removeFolder, role: .destructive) { remove(folder) }
                    }
                    .accessibilityAction(named: Copy.Files.removeFolder) { remove(folder) }
                    .accessibilityIdentifier("folders.row.\(index)")
            }
            Button {
                choose(replacing: nil)
            } label: {
                Label(Copy.Files.addFolder, systemImage: "folder.badge.plus")
                    .foregroundStyle(Palette.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .rowButtonStyle()
            .accessibilityHint(Copy.Files.chooseFoldersHint)
            .accessibilityIdentifier("folders.add")
        } header: {
            Text(Copy.Files.foldersHeader)
        } footer: {
            Text(Copy.Files.foldersFooter).fixedSize(horizontal: false, vertical: true)
        }
        .folderPicker(isPresented: $picking, replacing: choosingAgain)
        .confirmationDialog(
            confirmingRemove.map { Copy.Files.removeUnopenableTitle($0.name) } ?? "",
            isPresented: Binding(get: { confirmingRemove != nil }, set: { if !$0 { confirmingRemove = nil } }),
            titleVisibility: .visible,
            presenting: confirmingRemove
        ) { folder in
            Button(Copy.Files.chooseFolderAgain) { choose(replacing: folder.id) }
            Button(Copy.Files.removeFolder, role: .destructive) { Task { await files.removeFolder(folder.id) } }
            Button(Copy.General.cancel, role: .cancel) {}
        } message: { folder in
            Text(Copy.Files.removeUnopenableMessage(files.heldInUnopenableFolder(folder.id)))
        }
    }

    private func choose(replacing id: UUID?) {
        choosingAgain = id
        picking = true
    }

    private func remove(_ folder: FilesModel.Folder) {
        if files.heldInUnopenableFolder(folder.id) > 0 {
            confirmingRemove = folder
        } else {
            Task { await files.removeFolder(folder.id) }
        }
    }
}

/// One folder: its name and whether it still opens.
private struct FolderRow: View {
    let folder: FilesModel.Folder
    let chooseAgain: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: folder.isAvailable ? "folder" : "exclamationmark.triangle")
                .font(.body.weight(.medium))
                .foregroundStyle(folder.isAvailable ? Palette.accent : Palette.remove)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(folder.name)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text(folder.isAvailable ? Copy.Files.available : Copy.Files.unavailable)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.hair)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { if !folder.isAvailable { chooseAgain() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Files.folderLabel(folder.name, available: folder.isAvailable))
        .accessibilityAddTraits(folder.isAvailable ? [] : .isButton)
    }
}
