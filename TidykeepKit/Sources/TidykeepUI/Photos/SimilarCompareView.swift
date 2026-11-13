import SwiftUI
import TidykeepCore

/// Which two photos to compare, and the group they come from.
struct SimilarComparePair: Identifiable, Hashable {
    let groupID: String
    let memberIDs: Set<String>
    let topID: String
    let bottomID: String

    var id: String { "\(topID)|\(bottomID)" }
}

/// Two photos, one above the other, zoomed and panned together so the same spot can be checked
/// in both: eyes, focus, a blink. Each has its own keep or remove choice.
struct SimilarCompareView: View {
    let pair: SimilarComparePair

    @Environment(PhotosModel.self) private var photos
    @Environment(Notices.self) private var notices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var zoom = SimilarSharedZoom()
    @ViewState private var refusals = 0

    var body: some View {
        NavigationStack {
            Group {
                if let group = photos.similarGroup(pair.groupID, following: pair.memberIDs),
                   let top = group.member(pair.topID),
                   let bottom = group.member(pair.bottomID) {
                    content(group, top: top, bottom: bottom)
                        .onAppear {
                            notices.announce(Copy.Similar.compareAnnouncement(
                                top: Copy.Similar.compareName(top, in: group),
                                bottom: Copy.Similar.compareName(bottom, in: group)
                            ))
                        }
                } else {
                    // Removed or kept while open; nothing left to compare.
                    Text(Copy.Similar.groupGone)
                        .font(.headline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Palette.groupedBackground)
            .navigationTitle(Copy.Similar.compareTitle)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.General.done) { dismiss() }
                }
                if zoom.isZoomed {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Copy.Similar.resetZoom) { reset() }
                    }
                }
            }
        }
        .feedback(.warning, trigger: refusals)
    }

    private func content(_ group: PhotoGroup, top: AssetMeta, bottom: AssetMeta) -> some View {
        GeometryReader { proxy in
            // At accessibility sizes the pickers grow, so the photos give up some height.
            let chrome: CGFloat = typeSize.isAccessibilitySize ? 300 : 140
            let photoHeight = max(140, (proxy.size.height - chrome) / 2)
            ScrollView {
                VStack(spacing: Space.l) {
                    half(top, in: group, height: photoHeight, identifier: "compare.picker.top")
                    half(bottom, in: group, height: photoHeight, identifier: "compare.picker.bottom")
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
            }
            .scrollDisabled(zoom.isZoomed)
        }
    }

    private func half(_ meta: AssetMeta, in group: PhotoGroup, height: CGFloat, identifier: String) -> some View {
        let kept = photos.isKept(meta.id, in: group)
        return VStack(alignment: .leading, spacing: Space.s) {
            SimilarZoomedPhoto(id: meta.id, zoom: $zoom, height: height, reduceMotion: reduceMotion)
                .overlay(alignment: .topLeading) {
                    SimilarScrimCapsule(
                        text: Copy.Similar.compareName(meta, in: group),
                        symbol: meta.id == group.keeper.id ? "rosette" : nil
                    )
                    .padding(Space.m)
                }
                .overlay(alignment: .bottomTrailing) {
                    SimilarDecisionBadge(kept: kept, isProtected: group.isProtected(meta.id), size: .title2)
                        .padding(Space.m)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Copy.Similar.photoLabel(meta, in: group))
                .accessibilityValue(Copy.Similar.photoValue(meta, in: group, kept: kept))
                .accessibilityAddTraits(.isImage)
                .accessibilityZoomAction { action in
                    switch action.direction {
                    case .zoomIn: zoom.step(by: 1)
                    case .zoomOut: zoom.step(by: -1)
                    }
                }
            SimilarDecisionPicker(
                isKept: kept,
                label: Copy.Similar.decisionLabel(meta, in: group),
                identifier: identifier,
                resetToken: refusals
            ) { keep in
                photos.setKeep(keep, meta.id, in: group)
                if photos.isKept(meta.id, in: group) != keep { refusals += 1 }
            }
        }
    }

    private func reset() {
        withAnimation(Motion.standard(reduceMotion)) { zoom = SimilarSharedZoom() }
    }
}

/// The zoom both photos share: a scale from 1 to 5 and an offset, kept within the photo.
struct SimilarSharedZoom: Equatable {
    static let range: ClosedRange<CGFloat> = 1...5

    var scale: CGFloat = 1
    var offset: CGSize = .zero
    /// Where a pinch or drag began, so the gesture adds to it.
    var baseScale: CGFloat = 1
    var baseOffset: CGSize = .zero

    var isZoomed: Bool { scale > 1.01 }

    mutating func pinch(_ magnification: CGFloat) {
        scale = min(max(baseScale * magnification, Self.range.lowerBound), Self.range.upperBound)
        if !isZoomed { offset = .zero }
    }

    mutating func drag(_ translation: CGSize, in size: CGSize) {
        guard isZoomed else { return }
        offset = clamped(CGSize(width: baseOffset.width + translation.width, height: baseOffset.height + translation.height), in: size)
    }

    mutating func end(in size: CGSize) {
        offset = isZoomed ? clamped(offset, in: size) : .zero
        baseScale = scale
        baseOffset = offset
    }

    /// One VoiceOver zoom step, or a double tap (`step(by: 0)` toggles).
    mutating func step(by direction: Int) {
        switch direction {
        case 0: scale = isZoomed ? 1 : 2.5
        default: scale = min(max(scale + CGFloat(direction), Self.range.lowerBound), Self.range.upperBound)
        }
        if !isZoomed { offset = .zero }
        baseScale = scale
        baseOffset = offset
    }

    private func clamped(_ offset: CGSize, in size: CGSize) -> CGSize {
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }
}

/// One photo in Compare, filling its frame and following the shared zoom. Pinch to zoom, drag
/// to pan, double-tap to zoom in or out.
private struct SimilarZoomedPhoto: View {
    let id: String
    @Binding var zoom: SimilarSharedZoom
    let height: CGFloat
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            PhotoThumbnail(id: id, pixelSize: 1400, contentMode: .fill)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(zoom.scale)
                .offset(zoom.offset)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    MagnifyGesture()
                        .onChanged { zoom.pinch($0.magnification) }
                        .onEnded { _ in zoom.end(in: proxy.size) }
                        .simultaneously(with: DragGesture(minimumDistance: 8)
                            .onChanged { zoom.drag($0.translation, in: proxy.size) }
                            .onEnded { _ in zoom.end(in: proxy.size) })
                )
                .onTapGesture(count: 2) {
                    withAnimation(Motion.standard(reduceMotion)) { zoom.step(by: 0) }
                }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.preview, style: .continuous))
        .accessibilityIgnoresInvertColors()
    }
}
