import SwiftUI
import TidykeepCore

// MARK: - Screenshots

/// Every screenshot that could go, newest first, by month. Nothing starts marked. Tapping a
/// tile shows it; in select mode a tap marks it instead. "Mark all" marks one month.
struct ScreenshotsView: View {
    @Environment(PhotosModel.self) private var photos
    @Environment(Preferences.self) private var preferences
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var isSelecting: Bool
    @ViewState private var filter: Copy.Screenshots.Filter
    @ViewState private var review: ReviewRequest?
    @ViewState private var viewing: AssetMeta?

    init(isSelecting: Bool = false, filter: Copy.Screenshots.Filter = .all) {
        _isSelecting = ViewState(initialValue: isSelecting)
        _filter = ViewState(initialValue: filter)
    }

    var body: some View {
        content
            .background(Palette.groupedBackground)
            .navigationTitle(Copy.Screenshots.title)
            .toolbar {
                if !photos.screenshots.isEmpty {
                    ToolbarItem(placement: .topTrailing) { filterMenu }
                    ToolbarItem(placement: .topTrailing) {
                        Button(isSelecting ? Copy.General.done : Copy.General.select) {
                            withAnimation(Motion.standard(reduceMotion)) { isSelecting.toggle() }
                        }
                        .fontWeight(isSelecting ? .semibold : .regular)
                    }
                }
            }
            .actionBar(primary: removeAction)
            .reviewSheet($review)
            .sheet(item: $viewing) { ScreenshotViewer(meta: $0) }
            .feedback(.selection, trigger: photos.markedScreenshots)
    }

    // MARK: Content

    /// The screenshots under the chosen filter, newest first.
    private var shown: [AssetMeta] {
        let now = Date()
        return photos.screenshots.filter { filter.includes($0.creationDate, now: now) }
    }

    /// The marked screenshots the filter shows: the only ones counted, reviewed and removed.
    private var markedShown: [String] {
        shown.map(\.id).filter(photos.markedScreenshots.contains)
    }

    /// Marked screenshots the filter hides. They stay marked for when the filter changes back.
    private var hiddenMarkedCount: Int {
        photos.screenshots.count { photos.markedScreenshots.contains($0.id) } - markedShown.count
    }

    @ViewBuilder
    private var content: some View {
        if !photos.access.canRead {
            ScrollView {
                AccessOffView(title: Copy.Access.photosOff, detail: Copy.Access.photosOffDetail)
                    .padding(Space.l)
            }
        } else if photos.screenshots.isEmpty {
            ScrollView {
                VStack(spacing: Space.l) {
                    ScanStatusView(state: photos.scanState)
                    AllTidyView(detail: Copy.Screenshots.emptyDetail)
                }
                .padding(Space.l)
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        let shown = shown
        let index = Dictionary(uniqueKeysWithValues: shown.enumerated().map { ($1.id, $0) })
        let marked = shown.filter { photos.markedScreenshots.contains($0.id) }
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                header
                if shown.isEmpty {
                    Text(Copy.Screenshots.noneInFilter)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.xxl)
                }
                LazyVStack(alignment: .leading, spacing: Space.l) {
                    ForEach(ScreenshotMonth.sections(shown)) { section in
                        VStack(alignment: .leading, spacing: Space.s) {
                            MonthHeader(section: section)
                            LazyVGrid(columns: columns, spacing: Space.hair) {
                                ForEach(section.items) { meta in
                                    tile(meta, index: index[meta.id] ?? 0)
                                }
                            }
                        }
                    }
                }
                Text(Copy.Screenshots.keptSafeFooter(albums: preferences.rules.keepScreenshotsInAlbums))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.l)
                    .padding(.top, Space.s)
            }
            .padding(.bottom, Space.l)
        }
        .accessibilityRotor(Copy.Screenshots.markedRotor) {
            ForEach(marked) { meta in
                AccessibilityRotorEntry(Text(Copy.Screenshots.tileLabel(meta)), id: meta.id)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(Copy.Screenshots.summary(shown.count, marked: markedShown.count))
                .font(.subheadline.weight(.medium))
                .contentTransition(.numericText())
            if hiddenMarkedCount > 0 {
                Text(Copy.Screenshots.hiddenMarked(hiddenMarkedCount))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isSelecting {
                Text(Copy.Screenshots.selectHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.s)
        .accessibilityElement(children: .combine)
    }

    /// Four columns on a phone, one tile per 80 points; tiles keep their size at large text.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 80), spacing: Space.hair)]
    }

    private func tile(_ meta: AssetMeta, index: Int) -> some View {
        let isMarked = photos.markedScreenshots.contains(meta.id)
        return Button {
            if isSelecting { toggle(meta) } else { viewing = meta }
        } label: {
            ScreenshotTile(meta: meta, isMarked: isMarked, showsCircle: isSelecting)
        }
        .buttonStyle(.plain)
        .id(meta.id)
        .accessibilityLabel(Copy.Screenshots.tileLabel(meta))
        .accessibilityValue(isMarked ? Copy.Screenshots.marked : Copy.Screenshots.notMarked)
        .accessibilityAddTraits(isMarked ? .isSelected : [])
        .accessibilityHint(isSelecting ? "" : Copy.Screenshots.view)
        .accessibilityActions {
            Button(isMarked ? Copy.Screenshots.unmark : Copy.Screenshots.mark) { toggle(meta) }
            Button(Copy.Screenshots.view) { viewing = meta }
        }
        .accessibilityIdentifier("screenshot.tile.\(index)")
    }

    private func toggle(_ meta: AssetMeta) {
        withAnimation(Motion.standard(reduceMotion)) { _ = photos.toggleMarks([meta.id]) }
    }

    // MARK: Toolbar and bar

    private var filterMenu: some View {
        Menu {
            Picker(Copy.Screenshots.filter, selection: $filter) {
                ForEach(Copy.Screenshots.Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(Copy.Screenshots.filter, systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(Copy.Screenshots.filter)
        .accessibilityValue(filter.title)
    }

    /// "Remove 4 screenshots", once any on screen are marked. Marks the filter hides aren't
    /// part of it, so the count matches what's shown.
    private var removeAction: BarAction? {
        let ids = markedShown
        guard !ids.isEmpty else { return nil }
        return BarAction(
            title: Copy.Screenshots.removeButton(ids.count),
            systemImage: "trash",
            isBusy: photos.isWorking,
            hint: Copy.Copies.mergeHint
        ) {
            review = photos.screenshotsReview(ids, keepsAlbums: preferences.rules.keepScreenshotsInAlbums)
        }
    }
}

/// A month's name with "Mark all" or "Unmark all" for just that month.
private struct MonthHeader: View {
    let section: ScreenshotMonth
    @Environment(PhotosModel.self) private var photos
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ids = section.items.map(\.id)
        let allMarked = Set(ids).isSubset(of: photos.markedScreenshots)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Space.s))
        layout {
            Text(Copy.month(section.month))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if !typeSize.isAccessibilitySize { Spacer(minLength: Space.s) }
            Button(allMarked ? Copy.Screenshots.unmarkAll : Copy.Screenshots.markAll) {
                withAnimation(Motion.standard(reduceMotion)) { _ = photos.toggleMarks(ids) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.accent)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(allMarked ? Copy.Screenshots.unmarkAllLabel(section.month) : Copy.Screenshots.markAllLabel(section.month))
        }
        .padding(.horizontal, Space.l)
    }
}

/// A screenshot tile, phone-shaped and cropped from the top, with a check when marked.
private struct ScreenshotTile: View {
    let meta: AssetMeta
    let isMarked: Bool
    /// In select mode, unmarked tiles show an empty circle so it's clear they can be tapped.
    let showsCircle: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Color.clear
            .aspectRatio(9 / 19.5, contentMode: .fit)
            .overlay(alignment: .top) {
                PhotoThumbnail(id: meta.id, pixelSize: 360)
            }
            .clipped()
            .overlay {
                if isMarked {
                    Rectangle().fill(.black.opacity(contrast == .increased ? 0.35 : 0.2))
                }
            }
            .overlay {
                if isMarked && contrast == .increased {
                    Rectangle().strokeBorder(Palette.accent, lineWidth: 3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isMarked {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Palette.onAccent, Palette.accent)
                        .font(.title3)
                        .background(Circle().fill(.white).padding(2))
                        .padding(Space.s)
                        .transition(.opacity)
                } else if showsCircle {
                    Image(systemName: "circle")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .background(Circle().fill(.black.opacity(0.25)).padding(2))
                        .shadow(color: .black.opacity(0.3), radius: 1.5)
                        .padding(Space.s)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .accessibilityIgnoresInvertColors()
    }
}

// MARK: - Viewer

/// One screenshot, large, with the mark toggle at the bottom.
private struct ScreenshotViewer: View {
    let meta: AssetMeta
    @Environment(PhotosModel.self) private var photos
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let isMarked = photos.markedScreenshots.contains(meta.id)
        NavigationStack {
            PhotoThumbnail(id: meta.id, pixelSize: 1600, contentMode: .fit)
                .aspectRatio(aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Radius.preview, style: .continuous))
                .padding(Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Copy.Screenshots.tileLabel(meta))
                .accessibilityAddTraits(.isImage)
                .accessibilityIgnoresInvertColors()
                .navigationTitle(Copy.dayAndTime(meta.creationDate))
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Copy.General.done) { dismiss() }
                    }
                }
                .actionBar(primary: BarAction(
                    title: isMarked ? Copy.Screenshots.marked : Copy.Screenshots.mark,
                    systemImage: isMarked ? "checkmark.circle.fill" : "circle"
                ) {
                    photos.toggleMarks([meta.id])
                })
                .feedback(.selection, trigger: isMarked)
        }
    }

    private var aspect: CGFloat {
        guard meta.pixelWidth > 0, meta.pixelHeight > 0 else { return 9 / 19.5 }
        return CGFloat(meta.pixelWidth) / CGFloat(meta.pixelHeight)
    }
}
