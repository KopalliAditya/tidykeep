import TidykeepCore
import SwiftUI

/// One group: a big preview, every photo as a tile, and the keep/remove controls.
struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let groupID: String
    @ViewState private var selectedID: String?
    @ViewState private var memberIDs: Set<String> = []

    var body: some View {
        if let group = current {
            content(group)
                .onChange(of: group.id, initial: true) { memberIDs = Set(group.members.map(\.id)) }
        } else {
            // Removed or kept whole; go back to the list.
            Color.clear.onAppear { dismiss() }
        }
    }

    /// A group's id changes when a photo joins it (a scan in progress, a new shot), so follow
    /// its photos rather than close the screen under the user. Groups never share photos.
    private var current: PhotoGroup? {
        model.group(groupID) ?? model.groups.first { $0.members.contains { memberIDs.contains($0.id) } }
    }

    private func content(_ group: PhotoGroup) -> some View {
        let selected = selectedID.flatMap(group.member) ?? group.keeper
        let removing = model.removals(in: group).count
        let bar = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PreviewImage(meta: selected, group: group)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Copy.whyThisOne(group))
                        .font(.subheadline)
                        .accessibilityLabel(Copy.whyThisOneSpoken(group))
                    if group.ranking.isCloseCall {
                        Label {
                            Text(Copy.closeCall)
                        } icon: {
                            Image(systemName: "eye").foregroundStyle(.orange)
                        }
                        .font(.subheadline)
                        .accessibilityLabel(Copy.closeCallSpoken(group))
                    }
                }
                SelectedPhotoActions(meta: selected, group: group)
                Text("Photos")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(group.inCaptureOrder) { meta in
                        PhotoTile(meta: meta, group: group, isSelected: meta.id == selected.id) {
                            selectedID = meta.id
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(Copy.groupTitle(group))
        .inlineNavigationTitle()
        .safeAreaInset(edge: .bottom) {
            bar {
                Button {
                    model.keepAll(group)
                } label: {
                    Text("Keep all").frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityHint("Keeps every photo and hides this group")
                Button {
                    Task { await model.removeSuggested(in: group) }
                } label: {
                    Text(removing == 0 ? "Nothing to remove" : "Remove \(Copy.photos(removing))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(removing == 0 || model.isDeleting)
            }
            .padding()
            .background(.bar)
        }
    }
}

struct PreviewImage: View {
    let meta: AssetMeta
    let group: PhotoGroup

    var body: some View {
        PhotoThumbnail(id: meta.id, pixelSize: 1200, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(height: 360)
            .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                if meta.id == group.keeper.id {
                    Label("Best pick", systemImage: "star.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview. \(Copy.photoLabel(meta, in: group))\(meta.id == group.keeper.id ? ". Best pick" : "")")
            .accessibilityAddTraits(.isImage)
    }
}

/// Acts on the photo in the preview. VoiceOver labels name it, since "this" is only visual.
struct SelectedPhotoActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let meta: AssetMeta
    let group: PhotoGroup

    var body: some View {
        let kept = model.isKept(meta.id, in: group)
        let number = Copy.photoNumber(meta.id, in: group)
        let row = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        VStack(alignment: .leading, spacing: 8) {
            row {
                Button {
                    model.setKeep(!kept, meta.id, in: group)
                } label: {
                    Label(kept ? "Remove this one" : "Keep this one", systemImage: kept ? "trash" : "checkmark.circle")
                }
                .disabled(group.isProtected(meta.id))
                .accessibilityLabel(kept ? "Mark \(number) for removal" : "Keep \(number)")
                Button {
                    model.keepOnly(meta.id, in: group)
                } label: {
                    Label("Keep only this", systemImage: "star")
                }
                .accessibilityLabel("Keep only \(number)")
            }
            .buttonStyle(.bordered)
            if let note = Copy.protectedNote(meta, in: group) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PhotoTile: View {
    @Environment(AppModel.self) private var model
    let meta: AssetMeta
    let group: PhotoGroup
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let kept = model.isKept(meta.id, in: group)
        Button(action: onSelect) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { PhotoThumbnail(id: meta.id, pixelSize: 400) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(kept ? 1 : 0.5)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: kept ? "checkmark.circle.fill" : "trash.circle.fill")
                        .font(.title2)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, kept ? Color.green : Color.red)
                        .padding(4)
                }
                .overlay(alignment: .topLeading) {
                    if meta.id == group.keeper.id {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .foregroundStyle(.yellow)
                            .padding(5)
                            .background(.black.opacity(0.5), in: Circle())
                            .padding(4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.photoLabel(meta, in: group))
        .accessibilityValue(Copy.photoValue(meta, in: group, kept: kept))
        .accessibilityHint("Selects it for the buttons above")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: kept ? "Mark for removal" : "Keep") { model.setKeep(!kept, meta.id, in: group) }
        .accessibilityAction(named: "Keep only this one") { model.keepOnly(meta.id, in: group) }
        .sensoryFeedback(.selection, trigger: kept)
    }
}

extension View {
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
