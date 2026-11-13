import AVKit
import SwiftUI
import TidykeepCore

// MARK: - Big Videos

/// Videos over the minimum length, biggest first. Keep takes one off the list for good;
/// Remove always goes through the review sheet. Nothing starts marked.
struct BigVideosView: View {
    @Environment(PhotosModel.self) private var photos
    @Environment(Preferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var isSelecting: Bool
    @ViewState private var review: ReviewRequest?

    init(isSelecting: Bool = false) {
        _isSelecting = ViewState(initialValue: isSelecting)
    }

    var body: some View {
        content
            .background(Palette.groupedBackground)
            .navigationTitle(Copy.Videos.title)
            .toolbar {
                if !photos.videos.isEmpty {
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
            .feedback(.selection, trigger: photos.markedVideos)
            .animation(Motion.standard(reduceMotion), value: photos.videos.map(\.id))
    }

    @ViewBuilder
    private var content: some View {
        if !photos.access.canRead {
            ScrollView {
                AccessOffView(title: Copy.Access.photosOff, detail: Copy.Access.photosOffDetail)
                    .padding(Space.l)
            }
        } else if photos.videos.isEmpty {
            ScrollView {
                VStack(spacing: Space.l) {
                    ScanStatusView(state: photos.scanState)
                    AllTidyView(detail: Copy.Videos.emptyDetail)
                }
                .padding(Space.l)
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                Text(Copy.Videos.overMinimum(photos.videos.count, minimum: preferences.videoMinimum))
                    .font(.subheadline.weight(.medium))
                    .contentTransition(.numericText())
                    .accessibilityAddTraits(.isHeader)
                    .photoListNote()
            }
            Section {
                ForEach(Array(photos.videos.enumerated()), id: \.element.id) { index, meta in
                    row(meta)
                        .accessibilityIdentifier("video.row.\(index)")
                        .swipeActions(edge: .leading) {
                            Button(Copy.Videos.keep) { photos.keepVideo(meta.id) }
                                .tint(Palette.accent)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(Copy.Videos.remove) { review = single(meta) }
                                .tint(Palette.remove)
                        }
                        .accessibilityActions {
                            Button(Copy.Videos.keep) { photos.keepVideo(meta.id) }
                            Button(Copy.Videos.remove) { review = single(meta) }
                        }
                }
            }
            Section {
                Text(Copy.Videos.footer(kept: photos.ledger.keptVideoIDs.count))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .photoListNote()
            }
        }
        .groupedList()
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(_ meta: VideoMeta) -> some View {
        let isMarked = photos.markedVideos.contains(meta.id)
        if isSelecting {
            Button {
                withAnimation(Motion.standard(reduceMotion)) { toggle(meta.id) }
            } label: {
                VideoRow(meta: meta, mark: isMarked)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isMarked ? Copy.Screenshots.marked : Copy.Screenshots.notMarked)
            .accessibilityAddTraits(isMarked ? .isSelected : [])
        } else {
            NavigationLink(value: Route.video(meta.id)) {
                VideoRow(meta: meta, mark: nil)
            }
            .accessibilityValue(isMarked ? Copy.Screenshots.marked : "")
            .accessibilityAddTraits(isMarked ? .isSelected : [])
        }
    }

    private func toggle(_ id: String) {
        if photos.markedVideos.contains(id) {
            photos.markedVideos.remove(id)
        } else {
            photos.markedVideos.insert(id)
        }
    }

    private func single(_ meta: VideoMeta) -> ReviewRequest {
        photos.videosReview([meta.id], minimum: preferences.videoMinimum, title: Copy.Videos.removeTitle)
    }

    /// "Remove 2 videos", once any are marked.
    private var removeAction: BarAction? {
        let ids = photos.videos.map(\.id).filter(photos.markedVideos.contains)
        guard !ids.isEmpty else { return nil }
        return BarAction(
            title: Copy.Videos.removeButton(ids.count),
            systemImage: "trash",
            isBusy: photos.isWorking,
            hint: Copy.Copies.mergeHint
        ) {
            review = photos.videosReview(ids, minimum: preferences.videoMinimum)
        }
    }
}

/// One video: its poster with the length on it, the day it was taken, and its quality.
private struct VideoRow: View {
    let meta: VideoMeta
    /// Whether it's marked, in select mode; nil otherwise.
    let mark: Bool?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
            : AnyLayout(HStackLayout(spacing: Space.m))
        HStack(spacing: Space.m) {
            if let mark {
                Image(systemName: mark ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(mark ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            layout {
                VideoPoster(meta: meta, width: typeSize.isAccessibilitySize ? 160 : 112)
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(Copy.day(meta.creationDate))
                        .font(.body.weight(.semibold))
                    Text(Copy.Videos.quality(meta))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if meta.isFavorite {
                        Label(Copy.General.favorite, systemImage: "heart.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.xs)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Videos.rowLabel(meta))
    }
}

/// A video's poster frame, 16:9, with its length in the corner.
private struct VideoPoster: View {
    let meta: VideoMeta
    var width: CGFloat = 112

    var body: some View {
        PhotoThumbnail(id: meta.id, pixelSize: 400)
            .frame(width: width, height: width * 9 / 16)
            .overlay(alignment: .bottomTrailing) {
                Text(Copy.clock(meta.duration))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.xs + 1)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(Space.xs)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile * 2, style: .continuous))
            .accessibilityHidden(true)
            .accessibilityIgnoresInvertColors()
    }
}

// MARK: - Video detail

/// One video: plays it when it's on this iPhone, otherwise its poster and why it can't play.
/// Keep takes it off Big Videos; Remove goes through the review sheet.
struct VideoDetailView: View {
    let videoID: String
    @Environment(PhotosModel.self) private var photos
    @Environment(Preferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @ViewState private var player: AVPlayer?
    @ViewState private var loaded = false
    @ViewState private var review: ReviewRequest?

    var body: some View {
        let meta = photos.video(videoID)
        Group {
            if let meta {
                detail(meta)
            } else {
                AllTidyView(detail: Copy.Videos.gone)
                    .frame(maxHeight: .infinity)
            }
        }
        .background(Palette.groupedBackground)
        .navigationTitle(meta.map { Copy.day($0.creationDate) } ?? Copy.Videos.title)
        .inlineNavigationTitle()
        .task(id: videoID) { await load() }
        .onDisappear { player?.pause() }
        .reviewSheet($review)
    }

    /// Plays only a file already on this device. A video in iCloud stays there.
    private func load() async {
        if let url = await photos.videoURL(for: videoID), url.isFileURL {
            player = AVPlayer(url: url)
        }
        loaded = true
    }

    private func detail(_ meta: VideoMeta) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                stage(meta)
                facts(meta)
                Text(Copy.Videos.removesEverywhere)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.l)
            }
            .padding(Space.l)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .actionBar(
            secondary: BarAction(title: Copy.Videos.keep, systemImage: "checkmark", hint: Copy.Videos.keepHint) {
                player?.pause()
                photos.keepVideo(meta.id)
                dismiss()
            },
            primary: BarAction(
                title: Copy.Videos.removeVideo,
                systemImage: "trash",
                isBusy: photos.isWorking,
                hint: Copy.Copies.mergeHint
            ) {
                player?.pause()
                review = photos.videosReview([meta.id], minimum: preferences.videoMinimum, title: Copy.Videos.removeTitle) {
                    dismiss()
                }
            }
        )
    }

    @ViewBuilder
    private func stage(_ meta: VideoMeta) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.preview, style: .continuous)
        if let player {
            VideoPlayer(player: player)
                .aspectRatio(aspect(meta), contentMode: .fit)
                .frame(maxHeight: 420)
                .clipShape(shape)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Copy.Videos.rowLabel(meta))
        } else {
            VStack(alignment: .leading, spacing: Space.m) {
                PhotoThumbnail(id: meta.id, pixelSize: 1200, contentMode: .fit)
                    .aspectRatio(aspect(meta), contentMode: .fit)
                    .frame(maxHeight: 420)
                    .clipShape(shape)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Copy.Videos.rowLabel(meta))
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIgnoresInvertColors()
                if loaded {
                    Label(Copy.Videos.cantPlay, systemImage: "icloud")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func facts(_ meta: VideoMeta) -> some View {
        VStack(spacing: 0) {
            FactRow(title: Copy.Videos.taken, value: Copy.dayAndTime(meta.creationDate))
            Divider().padding(.leading, Space.l)
            FactRow(title: Copy.Videos.length, value: Copy.duration(meta.duration), spoken: Copy.Videos.spokenDuration(meta.duration))
            Divider().padding(.leading, Space.l)
            FactRow(
                title: Copy.Videos.size,
                value: "\(Copy.Videos.resolution(meta)) · \(Copy.pixels(meta.pixelWidth, meta.pixelHeight))",
                spoken: "\(Copy.Videos.resolution(meta)), \(Copy.pixelsSpoken(meta.pixelWidth, meta.pixelHeight))"
            )
            if meta.isFavorite {
                Divider().padding(.leading, Space.l)
                FactRow(title: Copy.General.favorite, value: "", symbol: "heart.fill")
            }
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func aspect(_ meta: VideoMeta) -> CGFloat {
        guard meta.pixelWidth > 0, meta.pixelHeight > 0 else { return 16 / 9 }
        return CGFloat(meta.pixelWidth) / CGFloat(meta.pixelHeight)
    }
}

/// "Length   12 min 34 sec" in the video's facts card.
private struct FactRow: View {
    let title: String
    let value: String
    var spoken: String?
    var symbol: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.hair))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Space.m))
        layout {
            Text(title)
                .font(.body)
            if !typeSize.isAccessibilitySize { Spacer(minLength: Space.s) }
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(Palette.favorite)
            } else {
                Text(value)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(symbol == nil ? "\(title): \(spoken ?? value)" : title)
    }
}
