import SwiftUI
import TidykeepCore

/// The Tidy tab: what was checked, the last change, then every kind of clutter the app finds,
/// photos first. Each card or row opens its list.
struct TidyHomeView: View {
    @Environment(AppState.self) private var state
    @Environment(PhotosModel.self) private var photos
    @Environment(FilesModel.self) private var files
    @Environment(ContactsModel.self) private var contacts
    @Environment(History.self) private var history
    @Environment(Preferences.self) private var preferences
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewState private var showsCoverage = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                photoSection
                filesSection
                contactsSection
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.groupedBackground)
        .navigationTitle(Copy.Tabs.tidy)
        .refreshable { state.checkAgain() }
        .actionBar(secondary: scanAction, primary: nil)
        .sheet(isPresented: $showsCoverage) { CoverageSheet(coverage: photos.coverage) }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ScanStatusView(state: photos.scanState)
            if photos.access.canRead, photos.scanState.progress != nil {
                Button { showsCoverage = true } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(Palette.accent)
                            .accessibilityHidden(true)
                        Text(Copy.Coverage.line(checked: photos.coverage.checked, skipped: photos.coverage.totalSkipped))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())
                        Image(systemName: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Copy.Coverage.line(checked: photos.coverage.checked, skipped: photos.coverage.totalSkipped))
                .accessibilityHint(Copy.Coverage.title)
                .accessibilityIdentifier("coverage.line")
            }
            if let last = history.lastChange {
                NavigationLink(value: Route.receipt(last.id)) {
                    HStack(spacing: Space.m) {
                        Image(systemName: Copy.Receipts.symbol(last.kind))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Space.hair) {
                            Text(Copy.Home.lastChange)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.secondaryText)
                                .textCase(.uppercase)
                            Text(Copy.Receipts.sentence(last))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(Space.m)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Copy.Home.lastChange): \(Copy.Receipts.sentence(last))")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("home.lastchange")
            }
        }
    }

    // MARK: Photos

    @ViewBuilder
    private var photoSection: some View {
        CardSection(title: Copy.Home.photos) {
            switch photos.access {
            case .notDetermined:
                AccessOffView(
                    title: Copy.Home.photos,
                    detail: Copy.Access.photosOffDetail,
                    symbol: "photo.on.rectangle",
                    ask: (Copy.Access.askPhotos, { Task { await photos.requestAccess() } })
                )
            case .denied:
                AccessOffView(title: Copy.Access.photosOff, detail: Copy.Access.photosOffDetail)
            case .limited, .full:
                VStack(alignment: .leading, spacing: Space.m) {
                    if photos.access == .limited {
                        Button { Task { await photos.chooseMorePhotos() } } label: {
                            Text(Copy.Access.chooseMore)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Palette.accent)
                                .frame(minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    LazyVGrid(columns: columns, spacing: Space.m) {
                        card(.similar)
                        card(.copies)
                        card(.screenshots)
                        card(.videos)
                    }
                }
            }
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Space.m, alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2)
    }

    private enum PhotoCard { case similar, copies, screenshots, videos }

    private func card(_ kind: PhotoCard) -> some View {
        let checking = photos.scanState.isActive
        let card: CategoryCard
        let route: Route
        let identifier: String
        switch kind {
        case .similar:
            route = .similar
            identifier = "home.card.similar"
            card = CategoryCard(
                title: Copy.Home.similar,
                symbol: "square.stack.3d.up",
                photoIDs: photos.similar.prefix(3).map(\.keeper.id),
                count: photos.similar.isEmpty ? nil : Copy.groups(photos.similar.count),
                detail: photos.similar.isEmpty ? nil : Copy.extraPhotos(photos.similarRemovalCount),
                isChecking: checking
            )
        case .copies:
            route = .copies
            identifier = "home.card.copies"
            card = CategoryCard(
                title: Copy.Home.copies,
                symbol: "square.on.square",
                photoIDs: photos.copies.prefix(3).map(\.keeper.id),
                count: photos.copies.isEmpty ? nil : Copy.sets(photos.copies.count),
                detail: photos.copies.isEmpty ? nil : Copy.extraCopies(photos.copyRemovalCount),
                isChecking: checking || !photos.copiesComplete && photos.scanState.progress == nil
            )
        case .screenshots:
            route = .screenshots
            identifier = "home.card.screenshots"
            card = CategoryCard(
                title: Copy.Home.screenshots,
                symbol: "camera.viewfinder",
                photoIDs: photos.screenshots.prefix(3).map(\.id),
                count: photos.screenshots.isEmpty ? nil : Copy.screenshots(photos.screenshots.count),
                detail: nil,
                isChecking: checking
            )
        case .videos:
            route = .videos
            identifier = "home.card.videos"
            card = CategoryCard(
                title: Copy.Home.videos,
                symbol: "video",
                photoIDs: photos.videos.prefix(3).map(\.id),
                count: photos.videos.isEmpty ? nil : Copy.videos(photos.videos.count),
                detail: "Over \(Copy.duration(preferences.videoMinimum))",
                isChecking: checking
            )
        }
        return NavigationLink(value: route) { card }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
    }

    // MARK: Files and contacts

    private var filesSection: some View {
        CardSection(title: Copy.Home.files, footer: files.folderCount == 0 ? "Choose folders in Files or iCloud Drive to look for duplicates and large files." : nil) {
            VStack(spacing: 0) {
                NavigationLink(value: Route.duplicateFiles) {
                    CategoryRow(
                        title: Copy.Home.duplicateFiles,
                        symbol: "doc.on.doc",
                        detail: files.folderCount == 0 ? Copy.Home.chooseFolders : (files.duplicateSetCount == 0 ? Copy.Home.folders(files.folderCount) : Copy.bytes(files.duplicateExtraBytes) + " in extra copies"),
                        value: files.folderCount == 0 ? nil : (files.isScanning && files.duplicateSetCount == 0 ? Copy.Home.checking : Copy.sets(files.duplicateSetCount))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.row.dupfiles")
                Divider().padding(.leading, 64)
                NavigationLink(value: Route.largeFiles) {
                    CategoryRow(
                        title: Copy.Home.largeFiles,
                        symbol: "externaldrive",
                        detail: files.largeFileCount == 0 ? "Over \(Copy.bytes(preferences.largeFileMinimum))" : Copy.bytes(files.largeFileBytes),
                        value: files.folderCount == 0 ? nil : Copy.files(files.largeFileCount)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.row.largefiles")
                Divider().padding(.leading, 64)
                NavigationLink(value: Route.holding) {
                    CategoryRow(
                        title: Copy.Home.holding,
                        symbol: "tray.full",
                        detail: files.holdingCount == 0 ? Copy.Home.empty : Copy.files(files.holdingCount),
                        value: files.holdingCount == 0 ? nil : Copy.bytes(files.holdingBytes),
                        tint: .indigo
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.row.holding")
            }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    private var contactsSection: some View {
        CardSection(title: Copy.Home.contacts) {
            NavigationLink(value: Route.contacts) {
                CategoryRow(
                    title: Copy.Home.duplicateContacts,
                    symbol: "person.2",
                    detail: contactsDetail,
                    value: contacts.access == .allowed && contacts.duplicateGroupCount > 0 ? Copy.count(contacts.duplicateGroupCount, "match", "matches") : nil,
                    tint: .green
                )
            }
            .buttonStyle(.plain)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .accessibilityIdentifier("home.row.contacts")
        }
    }

    private var contactsDetail: String {
        switch contacts.access {
        case .notDetermined: Copy.Home.allowContacts
        case .denied: "Contacts access is off"
        case .allowed:
            if contacts.isScanning { Copy.Home.checking }
            else if contacts.duplicateGroupCount == 0 { Copy.Home.noneFound }
            else { Copy.cards(contacts.extraCardCount) + " could merge" }
        }
    }

    // MARK: Bottom bar

    private var scanAction: BarAction? {
        guard photos.access.canRead || files.folderCount > 0 || contacts.access == .allowed else { return nil }
        if photos.scanState.isActive {
            return BarAction(title: "Pause", systemImage: "pause.fill") { photos.stopScan() }
        }
        return BarAction(title: Copy.General.checkAgain, systemImage: "arrow.clockwise") { state.checkAgain() }
    }
}
