import SwiftUI
import TidykeepCore

// MARK: - Copies list

/// Copy sets: the same picture saved more than once, however far apart. Each row shows the
/// copy that stays and why the others can go. Merging keeps one copy, gives it the favorite
/// and albums of the others, then removes them.
struct CopiesView: View {
    @Environment(PhotosModel.self) private var photos
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var review: ReviewRequest?

    var body: some View {
        content
            .background(Palette.groupedBackground)
            .navigationTitle(Copy.Copies.title)
            .actionBar(primary: mergeAction)
            .reviewSheet($review)
            .animation(Motion.standard(reduceMotion), value: photos.copies.map(\.id))
    }

    /// The copy pass is still running, so more sets may show up.
    private var isLooking: Bool { !photos.copiesComplete && photos.scanState.isActive }

    @ViewBuilder
    private var content: some View {
        if !photos.access.canRead {
            ScrollView {
                AccessOffView(title: Copy.Access.photosOff, detail: Copy.Access.photosOffDetail)
                    .padding(Space.l)
            }
        } else if photos.copies.isEmpty {
            ScrollView {
                VStack(spacing: Space.l) {
                    if isLooking {
                        CopiesLookingView(state: photos.scanState)
                    } else if case .stopped = photos.scanState {
                        InlineError(text: Copy.Scan.stopped) { photos.rescan() }
                    } else if case .failed = photos.scanState {
                        InlineError(text: Copy.Scan.failed) { photos.rescan() }
                    } else {
                        AllTidyView(detail: Copy.Copies.emptyDetail)
                    }
                }
                .padding(Space.l)
                .frame(maxWidth: .infinity)
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                CopiesHeader(sets: photos.copies.count, extras: photos.copyRemovalCount)
                    .photoListNote()
            }
            Section {
                ForEach(Array(photos.copies.enumerated()), id: \.element.id) { index, group in
                    NavigationLink(value: Route.copySet(group.id)) {
                        CopySetRow(group: group)
                    }
                    .accessibilityIdentifier("copies.row.\(index)")
                    .swipeActions(edge: .trailing) {
                        Button(Copy.Copies.merge) { review = photos.mergeReview(for: [group], title: Copy.Copies.mergeThisTitle, confirmTitle: Copy.Copies.mergeThisConfirm) }
                            .tint(Palette.accent)
                    }
                    .swipeActions(edge: .leading) {
                        Button(Copy.General.keepAll) { photos.keepAll(group) }
                            .tint(.gray)
                    }
                    .accessibilityActions {
                        Button(Copy.Copies.merge) { review = photos.mergeReview(for: [group], title: Copy.Copies.mergeThisTitle, confirmTitle: Copy.Copies.mergeThisConfirm) }
                        Button(Copy.General.keepAll) { photos.keepAll(group) }
                    }
                }
            }
            if isLooking {
                Section {
                    Label(Copy.Copies.stillLooking, systemImage: "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .photoListNote()
                }
            }
        }
        .groupedList()
        .scrollContentBackground(.hidden)
    }

    /// "Merge 3 sets". Hidden while checking, when sets may still change.
    private var mergeAction: BarAction? {
        let sets = photos.copies.filter { !photos.removals(in: $0).isEmpty }
        guard !sets.isEmpty, !photos.scanState.isActive else { return nil }
        return BarAction(
            title: Copy.Copies.mergeButton(sets.count),
            systemImage: "arrow.trianglehead.merge",
            isBusy: photos.isWorking,
            hint: Copy.Copies.mergeHint
        ) {
            review = photos.mergeReview(for: sets)
        }
    }
}

/// The line under the title, and what merging does, in the list's header.
private struct CopiesHeader: View {
    let sets: Int
    let extras: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(Copy.Copies.summary(sets: sets, extras: extras))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
            Text(Copy.Copies.explainer)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// No sets yet and the copy pass still running: says so, with the check's progress.
private struct CopiesLookingView: View {
    let state: PhotosModel.ScanState

    var body: some View {
        VStack(spacing: Space.l) {
            VStack(spacing: Space.m) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text(Copy.Copies.stillLooking)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Copy.Copies.explainer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.xl)
            .accessibilityElement(children: .combine)
            ScanStatusView(state: state)
        }
    }
}

/// One copy set: the copies fanned with the keeper on top, how many there are, and how the
/// others differ from the one that stays.
private struct CopySetRow: View {
    let group: PhotoGroup
    @Environment(PhotosModel.self) private var photos
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let removing = photos.removals(in: group).count
        let relation = relation
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
            : AnyLayout(HStackLayout(spacing: Space.m))
        layout {
            ThumbnailStack(ids: orderedIDs, symbol: "square.on.square", size: 52)
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(Copy.Copies.setTitle(group))
                    .font(.body.weight(.semibold))
                Text(Copy.Copies.relation(relation))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Copy.Copies.rowDetail(group, removing: removing))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Space.xs)
        .task(id: group.id) { await photos.loadFormats(for: group) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Copies.rowLabel(group, relation: relation, removing: removing))
    }

    /// The keeper first, so it sits on top of the stack.
    private var orderedIDs: [String] {
        let keeper = photos.copyKeeper(in: group).id
        return [keeper] + group.members.map(\.id).filter { $0 != keeper }
    }

    /// How the first copy that goes differs from the one that stays.
    private var relation: CopyRelation {
        guard let copy = photos.removals(in: group).first else { return CopyRelation.of(group, formats: photos.formats) }
        return photos.relation(of: copy, in: group)
    }
}

// MARK: - Copy set

/// One copy set: the copy that stays, why, every copy with its pixels, format and date, and
/// what the kept copy will have after merging. Tapping a copy makes it the one kept.
struct CopySetView: View {
    let groupID: String
    @Environment(PhotosModel.self) private var photos
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var review: ReviewRequest?

    var body: some View {
        let group = photos.group(groupID)
        Group {
            if let group {
                detail(group)
            } else {
                AllTidyView(detail: Copy.Copies.setGone)
                    .frame(maxHeight: .infinity)
            }
        }
        .background(Palette.groupedBackground)
        .navigationTitle(group.map(Copy.Copies.setTitle) ?? Copy.Copies.title)
        .inlineNavigationTitle()
        .task(id: groupID) {
            if let group { await photos.loadFormats(for: group) }
        }
        .reviewSheet($review)
        // Merged, kept or changed in Photos: back to the list.
        .onChange(of: group == nil) { _, gone in
            if gone { dismiss() }
        }
    }

    private func detail(_ group: PhotoGroup) -> some View {
        let keeper = photos.copyKeeper(in: group)
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                KeeperHero(meta: keeper, format: photos.formats[keeper.id])
                ReasonCard(reason: reason(group))
                members(group, keeper: keeper)
                Text(Copy.Copies.afterMerge(favorite: group.members.contains(where: \.isFavorite), albums: photos.albumTitles(for: group)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.l)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.l)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .feedback(.selection, trigger: keeper.id)
        .actionBar(
            secondary: BarAction(title: Copy.General.keepAll, systemImage: "checkmark") {
                photos.keepAll(group)
                dismiss()
            },
            primary: photos.removals(in: group).isEmpty ? nil : BarAction(
                title: Copy.Copies.merge,
                systemImage: "arrow.trianglehead.merge",
                isBusy: photos.isWorking,
                hint: Copy.Copies.mergeHint
            ) {
                review = photos.mergeReview(for: [group], title: Copy.Copies.mergeThisTitle, confirmTitle: Copy.Copies.mergeThisConfirm)
            }
        )
    }

    private func reason(_ group: PhotoGroup) -> Reason {
        let removing = photos.removals(in: group)
        let alsoKept = group.members.count - removing.count - 1
        let relation = removing.first.map { photos.relation(of: $0, in: group) } ?? CopyRelation.of(group, formats: photos.formats)
        return Reason(
            why: Copy.Copies.why(relation, keeperIsProtected: photos.copyKeeper(in: group).isProtected),
            keptSafe: alsoKept > 0 ? Copy.Copies.keptSafe(alsoKept) : nil,
            undo: Copy.Copies.undo(until: Receipt.recentlyDeletedDeadline(from: Date()))
        )
    }

    private func members(_ group: PhotoGroup, keeper: AssetMeta) -> some View {
        let lock = lock(group, keeper: keeper)
        return CardSection(title: Copy.Copies.membersHeader, footer: lock?.footer) {
            VStack(spacing: 0) {
                ForEach(Array(group.members.enumerated()), id: \.element.id) { index, meta in
                    let isKeeper = meta.id == keeper.id
                    CopyMemberRow(
                        meta: meta,
                        index: index + 1,
                        total: group.members.count,
                        group: group,
                        isKeeper: isKeeper,
                        lockReason: isKeeper || photos.canChooseCopy(meta.id, in: group) ? nil : lock?.row
                    ) {
                        withAnimation(Motion.standard(reduceMotion)) { photos.keepOnly(meta.id, in: group) }
                    }
                    if index < group.members.count - 1 {
                        Divider().padding(.leading, 56 + Space.l + Space.m)
                    }
                }
            }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    /// Why some copies can't be the one kept, for the footer and those rows, or nil when any
    /// copy can be chosen. A favorite or edited keeper decides it outright; otherwise a copy
    /// kept safe by the rules stays and takes the merge from any copy listed below it.
    private func lock(_ group: PhotoGroup, keeper: AssetMeta) -> (footer: String, row: String)? {
        if keeper.isProtected {
            return (Copy.Copies.protectedKeeper, Copy.Copies.cantChooseProtectedKeeper)
        }
        let blocked = group.members.contains { $0.id != keeper.id && !photos.canChooseCopy($0.id, in: group) }
        return blocked ? (Copy.Copies.keptSafeFirst, Copy.Copies.cantChooseKeptSafeFirst) : nil
    }
}

/// The copy that stays, large, with "Keeping this one" under it.
private struct KeeperHero: View {
    let meta: AssetMeta
    let format: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: Space.m) {
            PhotoThumbnail(id: meta.id, pixelSize: 1200, contentMode: .fit)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxHeight: typeSize.isAccessibilitySize ? 200 : 280)
                .clipShape(RoundedRectangle(cornerRadius: Radius.preview, style: .continuous))
                .accessibilityIgnoresInvertColors()
                .frame(maxWidth: .infinity)
            VStack(spacing: Space.hair) {
                Label(Copy.Copies.keeping, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                Text(Copy.Copies.memberLine(meta, format: format))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Copy.Copies.keeping): \(Copy.pixelsSpoken(meta.pixelWidth, meta.pixelHeight))\(format.map { ", \($0)" } ?? ""), \(Copy.day(meta.creationDate))")
        .accessibilityAddTraits(.isImage)
    }

    private var aspect: CGFloat {
        guard meta.pixelWidth > 0, meta.pixelHeight > 0 else { return 4 / 3 }
        return CGFloat(meta.pixelWidth) / CGFloat(meta.pixelHeight)
    }
}

/// One copy in a set, as a radio row: Keeping, Remove or Kept safe, with its pixels, format
/// and date. Tapping it keeps this copy instead. A copy that can't be the one kept isn't a
/// button: it shows no radio circle and says why.
private struct CopyMemberRow: View {
    let meta: AssetMeta
    let index: Int
    let total: Int
    let group: PhotoGroup
    let isKeeper: Bool
    /// Why this copy can't be chosen, or nil when it can (or already is).
    let lockReason: String?
    let choose: () -> Void
    @Environment(PhotosModel.self) private var photos
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if lockReason == nil {
            Button {
                if !isKeeper { choose() }
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAddTraits(isKeeper ? [.isSelected, .isButton] : .isButton)
            .accessibilityActions {
                if !isKeeper {
                    Button(Copy.Copies.keepThisInstead, action: choose)
                }
            }
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(value)
        }
    }

    private var content: some View {
        HStack(spacing: Space.m) {
            PhotoThumbnail(id: meta.id, pixelSize: 200)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: Radius.tile * 2, style: .continuous))
                .accessibilityIgnoresInvertColors()
            VStack(alignment: .leading, spacing: Space.hair) {
                HStack(spacing: Space.xs) {
                    Text(status)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isKeeper ? Palette.accent : .primary)
                    if meta.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.favorite)
                    }
                }
                Text(Copy.Copies.memberLine(meta, format: photos.formats[meta.id]))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if !isKeeper {
                    Text(Copy.Copies.relation(photos.relation(of: meta, in: group)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            if let symbol, !typeSize.isAccessibilitySize || isKeeper {
                Image(systemName: symbol)
                    .font(isKeeper || lockReason == nil ? .title3 : .body)
                    .foregroundStyle(isKeeper ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s + 2)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    /// A check on the keeper, a radio circle on copies that can be chosen, a lock on other
    /// copies kept safe, and nothing on a copy that goes and can't be chosen.
    private var symbol: String? {
        if isKeeper { return "checkmark.circle.fill" }
        if lockReason == nil { return "circle" }
        return isProtected ? "lock.fill" : nil
    }

    private var label: String {
        Copy.Copies.memberLabel(index: index, of: total, meta, format: photos.formats[meta.id])
    }

    private var value: String {
        // A copy kept safe stays either way, so "Kept safe" says enough.
        [status, meta.isFavorite ? Copy.General.favorite : nil, isProtected ? nil : lockReason]
            .compactMap { $0 }
            .joined(separator: ". ")
    }

    private var isProtected: Bool { group.isProtected(meta.id) }

    private var status: String {
        if isKeeper { return Copy.Copies.keepingStatus }
        if photos.isKept(meta.id, in: group) { return Copy.Copies.keptSafeStatus }
        return Copy.Copies.removeStatus
    }
}
