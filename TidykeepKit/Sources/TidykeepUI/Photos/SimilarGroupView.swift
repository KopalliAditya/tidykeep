import SwiftUI
import TidykeepCore

/// One group of similar shots: a large pager to look at each photo, the keep or remove choice
/// for the photo on screen, every photo as a tile, and why the best pick was chosen.
///
/// Looking and deciding are separate: tapping a tile only moves the pager; the segmented
/// control decides. The engine's defaults stand until the user changes them: the best pick and
/// protected photos stay, the rest are marked for removal.
struct SimilarGroupView: View {
    let groupID: String

    @Environment(PhotosModel.self) private var photos
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var pageID: String?
    @ViewState private var memberIDs: Set<String> = []
    @ViewState private var firstCount = 0
    @ViewState private var review: ReviewRequest?
    @ViewState private var compare: SimilarComparePair?
    @ViewState private var refusals = 0
    /// Bumped for each keep or remove change the model accepts, for the selection haptic.
    @ViewState private var changes = 0
    @ViewState private var removedBatches = 0
    @ViewState private var leaving = false
    @Namespace private var rotorSpace

    var body: some View {
        Group {
            if let group = photos.similarGroup(groupID, following: memberIDs) {
                content(group)
                    .onChange(of: group.id, initial: true) { remember(group) }
            } else if leaving {
                Color.clear
            } else {
                SimilarGroupGone { dismiss() }
                    .navigationTitle(Copy.Similar.title)
                    .inlineNavigationTitle()
            }
        }
        .background(Palette.groupedBackground)
        .reviewSheet($review)
        .sheet(item: $compare) { SimilarCompareView(pair: $0) }
        .feedback(.warning, trigger: refusals)
        .feedback(.selection, trigger: changes)
        .feedback(.success, trigger: removedBatches)
    }

    /// Follows the group's photos, so a check that adds a photo doesn't close the screen.
    private func remember(_ group: PhotoGroup) {
        memberIDs = Set(group.members.map(\.id))
        if firstCount == 0 { firstCount = group.members.count }
        if pageID.flatMap(group.member) == nil { pageID = group.keeper.id }
    }

    // MARK: Content

    private func content(_ group: PhotoGroup) -> some View {
        let current = pageID.flatMap(group.member) ?? group.keeper
        let removing = photos.removals(in: group)
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                if group.members.count < firstCount {
                    InlineError(text: Copy.Similar.changed(firstCount - group.members.count))
                        .padding(.horizontal, Space.l)
                }
                pager(group, current: current)
                whyLine(group)
                    .padding(.horizontal, Space.l)
                if group.ranking.isCloseCall {
                    closeCall(group)
                        .padding(.horizontal, Space.l)
                }
                decision(current, in: group)
                    .padding(.horizontal, Space.l)
                grid(group, current: current, removing: removing.count)
                    .padding(.horizontal, Space.l)
                ReasonCard(reason: photos.similarReason(group))
                    .padding(.horizontal, Space.l)
            }
            .padding(.top, Space.s)
            .padding(.bottom, Space.xl)
        }
        .navigationTitle(Copy.Similar.groupTitle(group))
        .inlineNavigationTitle()
        .toolbar { menu(group) }
        .actionBar(secondary: keepAllAction(group), primary: removeAction(group, count: removing.count))
        .disabled(photos.isWorking)
    }

    // MARK: Pager

    private var pagerHeight: CGFloat { typeSize.isAccessibilitySize ? 240 : 340 }

    /// The photos side by side, one per page. One adjustable element for VoiceOver: swipe up
    /// or down to move between photos.
    private func pager(_ group: PhotoGroup, current: AssetMeta) -> some View {
        let order = group.inCaptureOrder
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(order) { meta in
                    SimilarPagerPage(
                        meta: meta,
                        group: group,
                        kept: photos.isKept(meta.id, in: group)
                    )
                    .padding(.horizontal, Space.l)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pageID)
        .scrollIndicators(.hidden)
        .frame(height: pagerHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Similar.photoLabel(current, in: group))
        .accessibilityValue(Copy.Similar.photoValue(current, in: group, kept: photos.isKept(current.id, in: group)))
        .accessibilityHint(Copy.Similar.pagerHint)
        .accessibilityAddTraits(.isImage)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(by: 1, from: current, in: order)
            case .decrement: move(by: -1, from: current, in: order)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Copy.Similar.compare) { compare(with: current, in: group) }
    }

    private func move(by step: Int, from current: AssetMeta, in order: [AssetMeta]) {
        guard let index = order.firstIndex(where: { $0.id == current.id }) else { return }
        let next = min(max(index + step, 0), order.count - 1)
        withAnimation(Motion.standard(reduceMotion)) { pageID = order[next].id }
    }

    // MARK: Why

    /// Why the best pick was chosen, in the engine's words. VoiceOver also hears which photo it is.
    private func whyLine(_ group: PhotoGroup) -> some View {
        Label {
            Text(Copy.Similar.whyThisOne(group))
        } icon: {
            Image(systemName: "rosette").foregroundStyle(Palette.accent)
        }
        .labelStyle(SimilarCompactLabelStyle())
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Similar.whyThisOneSpoken(group))
        .accessibilityAddTraits(.isStaticText)
    }

    // MARK: Decision

    private func decision(_ meta: AssetMeta, in group: PhotoGroup) -> some View {
        let kept = photos.isKept(meta.id, in: group)
        let keepsOnly = group.members.allSatisfy { photos.isKept($0.id, in: group) == ($0.id == meta.id || group.isProtected($0.id)) }
        return VStack(alignment: .leading, spacing: Space.m) {
            SimilarDecisionPicker(
                isKept: kept,
                label: Copy.Similar.decisionLabel(meta, in: group),
                resetToken: refusals
            ) { keep in
                set(keep, meta, in: group)
            }
            if let note = Copy.Similar.protectedNote(meta, in: group) {
                Label {
                    Text(note)
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .labelStyle(SimilarCompactLabelStyle())
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            if group.members.count > 2 {
                // Once only this photo is kept, the button would do nothing, so it says so
                // instead: a dimmed button is too faint to read.
                if keepsOnly {
                    let alsoKept = group.members.count { $0.id != meta.id && group.isProtected($0.id) }
                    Label(Copy.Similar.keptOnlyThis(alsoAlwaysKept: alsoKept), systemImage: "checkmark")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                } else {
                    Button {
                        keepOnly(meta, in: group)
                    } label: {
                        Label(Copy.Similar.keepOnlyThis, systemImage: "rosette")
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                    .accessibilityLabel(Copy.Similar.keepOnlyLabel(meta, in: group))
                }
            }
        }
    }

    /// Asks for the change and notices when the model refuses it (a protected photo, or the
    /// last one kept), so the picker snaps back with a warning.
    private func set(_ keep: Bool, _ meta: AssetMeta, in group: PhotoGroup) {
        let was = photos.isKept(meta.id, in: group)
        photos.setKeep(keep, meta.id, in: group)
        let now = photos.isKept(meta.id, in: group)
        if now != keep { refusals += 1 } else if now != was { changes += 1 }
    }

    private func keepOnly(_ meta: AssetMeta, in group: PhotoGroup) {
        let before = photos.removals(in: group).map(\.id)
        photos.keepOnly(meta.id, in: group)
        if photos.removals(in: group).map(\.id) != before { changes += 1 }
    }

    // MARK: Close call

    /// The top two are nearly as good: a note and Compare. At accessibility sizes the button
    /// goes under the sentence so the sentence keeps the full width.
    private func closeCall(_ group: PhotoGroup) -> some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.m))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Space.m))
        return layout {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Image(systemName: "eye")
                    .foregroundStyle(Palette.closeCall)
                    .accessibilityHidden(true)
                Text(Copy.Similar.closeCall)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Copy.Similar.closeCallSpoken(group))
            }
            .layoutPriority(1)
            if !stacked { Spacer(minLength: 0) }
            // Large, so the button is at least 44 pt tall on iPhone.
            Button(Copy.Similar.compare) { compareBestTwo(group) }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(Palette.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(Palette.closeCall.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    // MARK: Grid

    private func grid(_ group: PhotoGroup, current: AssetMeta, removing: Int) -> some View {
        let order = group.inCaptureOrder
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(Copy.Similar.photosHeader)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
                    .textCase(.uppercase)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s)
                Text(Copy.Similar.keepRemove(kept: group.members.count - removing, removing: removing))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.secondaryText)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, Space.xs)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Space.hair)], spacing: Space.hair) {
                ForEach(order) { meta in
                    let kept = photos.isKept(meta.id, in: group)
                    SimilarPhotoTile(
                        meta: meta,
                        group: group,
                        kept: kept,
                        isCurrent: meta.id == current.id
                    ) {
                        withAnimation(Motion.standard(reduceMotion)) { pageID = meta.id }
                    }
                    .accessibilityActions {
                        Button(kept ? Copy.Similar.markForRemoval : Copy.Similar.keep) { set(!kept, meta, in: group) }
                        Button(Copy.Similar.keepOnlyThisOne) { keepOnly(meta, in: group) }
                        Button(Copy.Similar.compare) { compare(with: meta, in: group) }
                    }
                    .accessibilityRotorEntry(id: meta.id, in: rotorSpace)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .accessibilityRotor(Copy.Similar.markedRotor) {
                ForEach(order.filter { !photos.isKept($0.id, in: group) }) { meta in
                    AccessibilityRotorEntry(Text(Copy.Similar.photoLabel(meta, in: group)), id: meta.id, in: rotorSpace)
                }
            }
            .accessibilityRotor(Copy.Similar.keptRotor) {
                ForEach(order.filter { photos.isKept($0.id, in: group) }) { meta in
                    AccessibilityRotorEntry(Text(Copy.Similar.photoLabel(meta, in: group)), id: meta.id, in: rotorSpace)
                }
            }
        }
    }

    // MARK: Compare

    private func compareBestTwo(_ group: PhotoGroup) {
        guard let other = group.runnerUp ?? group.members.dropFirst().first else { return }
        compare = SimilarComparePair(groupID: group.id, memberIDs: memberIDs, topID: group.keeper.id, bottomID: other.id)
    }

    /// The best pick on top and this photo below; for the best pick itself, the runner-up.
    private func compare(with meta: AssetMeta, in group: PhotoGroup) {
        guard meta.id != group.keeper.id else { return compareBestTwo(group) }
        compare = SimilarComparePair(groupID: group.id, memberIDs: memberIDs, topID: group.keeper.id, bottomID: meta.id)
    }

    // MARK: Actions

    private func keepAllAction(_ group: PhotoGroup) -> BarAction {
        BarAction(title: Copy.General.keepAll, hint: Copy.Similar.keepAllHint) {
            leaving = true
            photos.keepAll(group)
            dismiss()
        }
    }

    private func removeAction(_ group: PhotoGroup, count: Int) -> BarAction? {
        guard count > 0 else { return nil }
        return BarAction(
            title: Copy.Similar.removeButton(count),
            isBusy: photos.isWorking,
            hint: Copy.Similar.removeHint
        ) {
            reviewRemoval(group)
        }
    }

    /// After a removal the group is done, so the screen goes back to the list, which moves
    /// focus to the next row. Cancelled in the iOS alert, or nothing removed: stay put.
    private func reviewRemoval(_ group: PhotoGroup) {
        let ids = Set(group.members.map(\.id))
        guard var request = photos.similarReview([group], done: { removed in
            if removed { removedBatches += 1 }
            if photos.similarGroup(group.id, following: ids) == nil {
                dismiss()
            } else {
                leaving = false
            }
        }) else { return }
        // The group leaves the model before the screen pops; show nothing in between rather
        // than the "gone" state.
        let remove = request.confirm
        request.confirm = {
            leaving = true
            await remove()
        }
        review = request
    }

    @ToolbarContentBuilder
    private func menu(_ group: PhotoGroup) -> some ToolbarContent {
        ToolbarItem(placement: .topTrailing) {
            Menu {
                Button { compareBestTwo(group) } label: {
                    Label(Copy.Similar.compareBestTwo, systemImage: "rectangle.split.1x2")
                }
                Button {
                    leaving = true
                    photos.keepAll(group)
                    dismiss()
                } label: {
                    Label(Copy.General.keepAll, systemImage: "checkmark.circle")
                }
            } label: {
                Label(Copy.Similar.more, systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
        }
    }
}

// MARK: - Pieces

/// One page of the pager: the photo, fitted, with the best pick and the page number on dark
/// capsules over it (never glass: the photo is the content).
private struct SimilarPagerPage: View {
    let meta: AssetMeta
    let group: PhotoGroup
    let kept: Bool

    /// The photo's shape, so the labels sit on its corners rather than on a letterbox.
    private var aspect: CGFloat {
        meta.pixelWidth > 0 && meta.pixelHeight > 0 ? CGFloat(meta.pixelWidth) / CGFloat(meta.pixelHeight) : 4 / 3
    }

    var body: some View {
        PhotoThumbnail(id: meta.id, pixelSize: 1400, contentMode: .fill)
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Radius.preview, style: .continuous))
            .accessibilityIgnoresInvertColors()
            .overlay(alignment: .topLeading) {
                if meta.id == group.keeper.id {
                    SimilarScrimCapsule(text: Copy.Similar.bestPick, symbol: "rosette")
                        .padding(Space.m)
                }
            }
            .overlay(alignment: .topTrailing) {
                SimilarScrimCapsule(text: Copy.Similar.pageCount(group.captureIndex(of: meta.id) ?? 1, of: group.members.count))
                    .monospacedDigit()
                    .padding(Space.m)
            }
            .overlay(alignment: .bottomTrailing) {
                SimilarDecisionBadge(kept: kept, isProtected: group.isProtected(meta.id), size: .title2)
                    .padding(Space.m)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// White text on a dark capsule, for labels over photos.
struct SimilarScrimCapsule: View {
    let text: String
    var symbol: String?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: Space.xs) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.footnote.weight(.semibold))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .foregroundStyle(.white)
        .padding(.horizontal, Space.s + 2)
        .padding(.vertical, Space.xs + 1)
        .background(.black.opacity(contrast == .increased || reduceTransparency ? 0.75 : 0.45), in: Capsule())
        .accessibilityHidden(true)
    }
}

/// Keep or remove, at a glance: an accent check, a red trash, or a lock for photos the rules
/// keep. Paired with dimming on the tiles, so it never relies on colour alone.
struct SimilarDecisionBadge: View {
    let kept: Bool
    let isProtected: Bool
    var size: Font = .title3

    var body: some View {
        Image(systemName: isProtected ? "lock.circle.fill" : kept ? "checkmark.circle.fill" : "trash.circle.fill")
            .font(size)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .symbolRenderingMode(.palette)
            .foregroundStyle(
                isProtected || !kept ? Color.white : Palette.onAccent,
                isProtected ? Color.black.opacity(0.55) : kept ? Palette.accent : Palette.remove
            )
            .contentTransition(.symbolEffect(.replace))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .accessibilityHidden(true)
    }
}

/// A square tile in the group grid. Tapping it shows the photo in the pager; the decision is
/// made with the picker or the tile's VoiceOver actions.
private struct SimilarPhotoTile: View {
    let meta: AssetMeta
    let group: PhotoGroup
    let kept: Bool
    let isCurrent: Bool
    let select: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Increased Contrast swaps the dimming for a red border, which reads better.
        let highContrast = contrast == .increased
        Button(action: select) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    PhotoThumbnail(id: meta.id, pixelSize: 300)
                        .opacity(kept || highContrast ? 1 : 0.55)
                        .accessibilityIgnoresInvertColors()
                }
                .clipped()
                .overlay {
                    if !kept && highContrast {
                        Rectangle().strokeBorder(Palette.remove, lineWidth: 3)
                    }
                }
                .overlay {
                    if isCurrent {
                        ZStack {
                            Rectangle().strokeBorder(Palette.accent, lineWidth: 3)
                            if differentiate {
                                Rectangle().strokeBorder(.white, lineWidth: 2).padding(3)
                            }
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if meta.id == group.keeper.id {
                        SimilarBestPickBadge().padding(Space.xs + 2)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    SimilarDecisionBadge(kept: kept, isProtected: group.isProtected(meta.id))
                        .padding(Space.xs + 2)
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: kept)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Similar.photoLabel(meta, in: group))
        .accessibilityValue(Copy.Similar.photoValue(meta, in: group, kept: kept))
        .accessibilityHint(Copy.Similar.tileHint)
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
    }
}

/// Keep or Remove for one photo. A segmented control; at accessibility text sizes, two
/// stacked buttons so neither word is cut off.
///
/// The segmented control shows its own selection, which the model can refuse (a protected
/// photo, or the last one kept). `resetToken` changes on a refusal and puts the selection back
/// to what the model says. The control keeps its identity, so VoiceOver stays on it while
/// the refusal is read out. The stacked buttons read the model directly and need no reset.
struct SimilarDecisionPicker: View {
    let isKept: Bool
    let label: String
    var identifier = "decision.picker"
    var resetToken = 0
    let set: (Bool) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewState private var shown: Choice?

    private enum Choice: Hashable { case keep, remove }

    private var modelChoice: Choice { isKept ? .keep : .remove }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: Space.s) {
                    button(.keep)
                    button(.remove)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
            } else {
                Picker(selection: Binding(
                    get: { shown ?? modelChoice },
                    set: { choice in
                        shown = choice
                        set(choice == .keep)
                    }
                )) {
                    Text(Copy.Similar.keep).tag(Choice.keep)
                    Text(Copy.Similar.remove).tag(Choice.remove)
                } label: {
                    Text(label)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .onChange(of: resetToken) { shown = nil }
                .onChange(of: isKept) { shown = nil }
                .onChange(of: label) { shown = nil }
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private func button(_ choice: Choice) -> some View {
        let selected = (choice == .keep) == isKept
        return Button {
            if !selected { set(choice == .keep) }
        } label: {
            Label(choice == .keep ? Copy.Similar.keep : Copy.Similar.remove, systemImage: selected ? "checkmark.circle.fill" : "circle")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(selected ? Palette.accent : Palette.secondaryText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The group was removed or kept elsewhere, or Photos changed it so fewer than two are left.
private struct SimilarGroupGone: View {
    let back: () -> Void

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text(Copy.Similar.groupGone)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(Copy.Similar.goneDetail)
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(Copy.Similar.backToList, action: back)
                .buttonStyle(.glass)
                .foregroundStyle(Palette.accent)
                .controlSize(.large)
                .padding(.top, Space.s)
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
