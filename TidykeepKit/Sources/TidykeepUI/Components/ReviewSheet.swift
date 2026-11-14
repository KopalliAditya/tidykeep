import SwiftUI

/// One thing in a review: a photo (shown as a tile), a file or a contact card.
struct ReviewItem: Hashable, Identifiable {
    enum Kind: Hashable {
        case photo
        case file(name: String, bytes: Int64)
        case contact(name: String)
    }

    let id: String
    let kind: Kind

    static func photo(_ id: String) -> ReviewItem { ReviewItem(id: id, kind: .photo) }
    static func file(id: String, name: String, bytes: Int64) -> ReviewItem { ReviewItem(id: id, kind: .file(name: name, bytes: bytes)) }
    static func contact(id: String, name: String) -> ReviewItem { ReviewItem(id: id, kind: .contact(name: name)) }
}

/// What the review sheet asks about. Every removal, move and merge goes through one.
struct ReviewRequest: Identifiable {
    let id = UUID()
    /// "Remove 9 photos?". UI tests look for a title starting "Remove " or "Merge ".
    var title: String
    var removing: [ReviewItem]
    var staying: [ReviewItem]
    var reason: Reason
    /// Shown when any photo may be in a Shared Library.
    var sharedLibraryLine: String?
    /// "Remove 9 photos"
    var confirmTitle: String
    /// Runs after the sheet closes, so iOS's own confirmation can show on top of the screen.
    var confirm: @MainActor () async -> Void
}

/// "You're about to…": what goes, what stays, why, and how to undo. The confirm button is the
/// accent colour, not red: for photos, iOS's own alert is the red final step.
struct ReviewSheet: View {
    let request: ReviewRequest
    @Environment(\.dismiss) private var dismiss
    @ViewState private var side = Side.removing

    enum Side: Hashable { case removing, staying }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    Text(request.title)
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("review.title")

                    if !request.staying.isEmpty {
                        Picker(selection: $side) {
                            Text("\(Copy.Review.removing) \(request.removing.count.formatted())").tag(Side.removing)
                            Text("\(Copy.Review.staying) \(request.staying.count.formatted())").tag(Side.staying)
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.segmented)
                    }

                    ReviewMosaic(items: side == .removing ? request.removing : request.staying, marksRemoval: side == .removing)

                    ReasonCard(reason: request.reason)

                    if let line = request.sharedLibraryLine {
                        Label(line, systemImage: "person.2")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Space.l)
            }
            .background(Palette.groupedBackground)
            .bottomBar {
                Button {
                    let confirm = request.confirm
                    dismiss()
                    Task { @MainActor in await confirm() }
                } label: {
                    Text(request.confirmTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .prominentGlassButton()
                .tint(Palette.accent)
                .controlSize(.large)
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
                .accessibilityIdentifier("review.confirm")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.General.cancel) { dismiss() }
                        .accessibilityIdentifier("review.cancel")
                }
            }
            .inlineNavigationTitle()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// Photos as a grid of tiles (the first 23, then "+N"); files and cards as rows.
struct ReviewMosaic: View {
    let items: [ReviewItem]
    let marksRemoval: Bool
    private static let shown = 23

    var body: some View {
        let photos = items.filter { $0.kind == .photo }
        let others = items.filter { $0.kind != .photo }
        VStack(alignment: .leading, spacing: Space.m) {
            if !photos.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: Space.xs)], spacing: Space.xs) {
                    ForEach(photos.prefix(Self.shown)) { item in
                        // The square comes from the clear colour; a filled photo would set its own shape.
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { PhotoThumbnail(id: item.id, pixelSize: 200) }
                            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                if marksRemoval {
                                    Image(systemName: "minus.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Palette.remove)
                                        .padding(Space.xs)
                                }
                            }
                    }
                    if photos.count > Self.shown {
                        RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                            .fill(Palette.fill)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { Text(Copy.Review.moreCount(photos.count - Self.shown)).font(.headline).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(marksRemoval ? "\(Copy.Review.removing): \(Copy.photos(photos.count))" : "\(Copy.Review.staying): \(Copy.photos(photos.count))")
            }
            if !others.isEmpty {
                VStack(spacing: 0) {
                    ForEach(others.prefix(50)) { item in
                        row(item)
                        if item.id != others.prefix(50).last?.id { Divider().padding(.leading, 44) }
                    }
                    if others.count > 50 {
                        Text(Copy.Review.moreCount(others.count - 50))
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(Space.m)
                    }
                }
                .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ReviewItem) -> some View {
        switch item.kind {
        case .photo:
            EmptyView()
        case .file(let name, let bytes):
            // Whole names, so two similar files can be told apart; the size goes under the
            // name at accessibility text sizes.
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Image(systemName: "doc").foregroundStyle(Palette.accent).frame(width: 24).accessibilityHidden(true)
                AdaptiveStack(spacing: Space.s) {
                    Text(name)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Copy.bytes(bytes)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.subheadline)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s + 2)
            .accessibilityElement(children: .combine)
        case .contact(let name):
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Image(systemName: "person.crop.circle").foregroundStyle(Palette.accent).frame(width: 24).accessibilityHidden(true)
                Text(name).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s + 2)
            .accessibilityElement(children: .combine)
        }
    }
}

extension View {
    /// Presents the review sheet for a request; set it to nil to close.
    func reviewSheet(_ request: Binding<ReviewRequest?>) -> some View {
        sheet(item: request) { ReviewSheet(request: $0) }
    }
}
