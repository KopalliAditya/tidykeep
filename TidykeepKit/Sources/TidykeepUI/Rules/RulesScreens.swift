import SwiftUI
import TidykeepCore

// MARK: - Rules

/// The Rules tab: what Tidykeep always keeps, what it looks at, the folders it checks, contacts
/// access, haptics, saved data and About. Protection changes apply to what's on screen right
/// away; the rest takes effect on the next check.
struct RulesView: View {
    @Environment(AppState.self) private var state
    @Environment(PhotosModel.self) private var photos
    @Environment(FilesModel.self) private var files
    @Environment(ContactsModel.self) private var contacts
    @Environment(History.self) private var history
    @Environment(Preferences.self) private var preferences
    @AppStorage(Haptics.key) private var hapticsOn = true
    @ViewState private var confirmsForget = false
    @ViewState private var confirmsClear = false

    var body: some View {
        Form {
            alwaysKeep
            whatToLookAt
            FoldersSection()
            ContactsRulesSection()
            haptics
            savedData
            about
        }
        .formStyle(.grouped)
        .navigationTitle(Copy.Tabs.rules)
        .minimizingTabBar()
    }

    // MARK: Always keep

    private var alwaysKeep: some View {
        Section {
            LabeledContent {
                Text(Copy.Rules.always)
            } label: {
                Label(Copy.Rules.favorites, systemImage: "heart")
            }
            LabeledContent {
                Text(Copy.Rules.always)
            } label: {
                Label(Copy.Rules.edited, systemImage: "slider.horizontal.3")
            }
            LabeledContent {
                Text(Copy.Rules.neverChecked)
            } label: {
                Label(Copy.Rules.hidden, systemImage: "eye.slash")
            }
            NavigationLink(value: Route.albums) {
                LabeledContent {
                    Text(Copy.Rules.albumsChosen(chosenAlbumCount))
                } label: {
                    Label(Copy.Rules.albums, systemImage: "rectangle.stack")
                }
            }
            Toggle(isOn: keepScreenshotsInAlbums) {
                wrapping(Copy.Rules.screenshotsInAlbums, systemImage: "camera.viewfinder")
            }
            Toggle(isOn: hideRecentFiles) {
                wrapping(Copy.Rules.recentFiles, systemImage: "doc.badge.clock")
            }
        } header: {
            Text(Copy.Rules.alwaysKeep)
        } footer: {
            Text(Copy.Rules.alwaysKeepFooter)
        }
    }

    /// A toggle's label that wraps at large text sizes instead of being cut off beside the switch.
    private func wrapping(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
    }

    /// Chosen albums that still exist, so a deleted album doesn't count.
    private var chosenAlbumCount: Int {
        let chosen = preferences.rules.albumIDs
        guard !photos.albums.isEmpty else { return chosen.count }
        return photos.albums.filter { chosen.contains($0.id) }.count
    }

    private var keepScreenshotsInAlbums: Binding<Bool> {
        Binding {
            preferences.rules.keepScreenshotsInAlbums
        } set: {
            preferences.rules.keepScreenshotsInAlbums = $0
            photos.refresh()
        }
    }

    private var hideRecentFiles: Binding<Bool> { Self.hideRecentFiles(preferences) }

    /// The "files changed in the last 7 days" toggle. Off is saved as 0 days rather than nil:
    /// `ProtectionRules` reads a missing value as the 7-day default, so nil would turn the rule
    /// back on at the next launch.
    static func hideRecentFiles(_ preferences: Preferences) -> Binding<Bool> {
        Binding {
            (preferences.rules.hideFilesChangedWithinDays ?? 0) > 0
        } set: {
            preferences.rules.hideFilesChangedWithinDays = $0 ? recentFileDays : 0
        }
    }

    static let recentFileDays = 7

    // MARK: What to look at

    private var whatToLookAt: some View {
        Section {
            Picker(Copy.Rules.photosFrom, selection: Binding(get: { preferences.scope }, set: { preferences.scope = $0 })) {
                ForEach(ScanScope.allCases) { Text($0.title).tag($0) }
            }
            Picker(Copy.Rules.howAlike, selection: Binding(get: { preferences.sensitivity }, set: { preferences.sensitivity = $0 })) {
                ForEach(Sensitivity.allCases) { Text($0.title).tag($0) }
            }
            Picker(Copy.Rules.bigVideos, selection: Binding(get: { preferences.videoMinimum }, set: { preferences.videoMinimum = $0 })) {
                ForEach(Preferences.videoMinimums, id: \.self) { Text(Copy.duration($0)).tag($0) }
            }
            Picker(Copy.Rules.largeFiles, selection: Binding(get: { preferences.largeFileMinimum }, set: { preferences.largeFileMinimum = $0 })) {
                ForEach(Preferences.largeFileMinimums, id: \.self) { Text(Copy.bytes($0)).tag($0) }
            }
        } header: {
            Text(Copy.Rules.whatToLookAt)
        } footer: {
            Text(Copy.Rules.takesEffect)
        }
    }

    // MARK: Haptics

    private var haptics: some View {
        Section {
            Toggle(Copy.Rules.haptics, isOn: $hapticsOn)
        } header: {
            Text(Copy.Rules.haptics)
        } footer: {
            Text(Copy.Rules.hapticsFooter)
        }
    }

    // MARK: Saved data

    private var savedData: some View {
        Section {
            Button(Copy.Rules.forgetAnalysis, role: .destructive) { confirmsForget = true }
                .rowButtonStyle()
                .foregroundStyle(Palette.remove)
                .confirmationDialog(Copy.Rules.forgetTitle, isPresented: $confirmsForget, titleVisibility: .visible) {
                    Button(Copy.Rules.forgetConfirm, role: .destructive) {
                        Task { await photos.forgetAnalysis() }
                    }
                    Button(Copy.General.cancel, role: .cancel) {}
                } message: {
                    Text(Copy.Rules.forgetMessage)
                }
            Button(Copy.Rules.clearHistory, role: .destructive) { confirmsClear = true }
                .rowButtonStyle()
                .foregroundStyle(history.receipts.isEmpty ? Palette.secondaryText : Palette.remove)
                .disabled(history.receipts.isEmpty)
                .confirmationDialog(Copy.Rules.clearTitle, isPresented: $confirmsClear, titleVisibility: .visible) {
                    Button(Copy.Rules.clearConfirm, role: .destructive) { state.clearHistory() }
                    Button(Copy.General.cancel, role: .cancel) {}
                } message: {
                    Text(Copy.Rules.clearMessage)
                }
        } header: {
            Text(Copy.Rules.savedData)
        } footer: {
            Text(Copy.Rules.savedDataFooter)
        }
    }

    // MARK: About

    private var about: some View {
        Section {
            NavigationLink(value: Route.about) {
                Label(Copy.Rules.aboutApp(), systemImage: "info.circle")
            }
        } header: {
            Text(Copy.Rules.about)
        }
    }
}

// MARK: - Albums

/// Albums to keep: every photo in a chosen album is never suggested. A change applies to the
/// lists straight away.
struct AlbumPickerView: View {
    @Environment(PhotosModel.self) private var photos
    @Environment(Preferences.self) private var preferences
    @ViewState private var query = ""

    /// Past this many albums, a search field helps.
    static let searchThreshold = 15

    var body: some View {
        content
            .navigationTitle(Copy.Rules.albums)
            .inlineNavigationTitle()
    }

    @ViewBuilder
    private var content: some View {
        if !photos.access.canRead {
            ContentUnavailableView(Copy.Access.photosOff, systemImage: "photo.on.rectangle", description: Text(Copy.Rules.photosOffDetail))
        } else if photos.albums.isEmpty {
            ContentUnavailableView(Copy.Rules.noAlbumsTitle, systemImage: "rectangle.stack", description: Text(Copy.Rules.noAlbumsDetail))
        } else if photos.albums.count > Self.searchThreshold {
            list.searchable(text: $query, prompt: Copy.Rules.searchAlbums)
        } else {
            list
        }
    }

    private var list: some View {
        Form {
            Section {
                ForEach(shown) { album in
                    AlbumRow(album: album, isChosen: preferences.rules.albumIDs.contains(album.id)) {
                        toggle(album)
                    }
                }
            } footer: {
                Text(Copy.Rules.albumsFooter)
            }
        }
        .formStyle(.grouped)
    }

    private var shown: [PhotoAlbum] {
        let sorted = photos.albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? sorted : sorted.filter { $0.title.localizedStandardContains(trimmed) }
    }

    private func toggle(_ album: PhotoAlbum) {
        if preferences.rules.albumIDs.contains(album.id) {
            preferences.rules.albumIDs.remove(album.id)
        } else {
            preferences.rules.albumIDs.insert(album.id)
        }
        photos.refresh()
    }
}

/// An album with its cover, name and count, and a checkmark when its photos are kept.
private struct AlbumRow: View {
    let album: PhotoAlbum
    let isChosen: Bool
    let toggle: () -> Void
    @ScaledMetric(relativeTo: .body) private var cover: CGFloat = 44

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Space.m) {
                coverImage
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(album.title)
                        .foregroundStyle(.primary)
                    Text(Copy.photos(album.assetIDs.count))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Palette.secondaryText)
                }
                Spacer(minLength: Space.s)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .opacity(isChosen ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .rowButtonStyle()
        .feedback(.selection, trigger: isChosen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(album.title), \(Copy.photos(album.assetIDs.count))")
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var coverImage: some View {
        let side = min(cover, 72)
        if let first = album.assetIDs.sorted().first {
            PhotoThumbnail(id: first, pixelSize: 160)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.fill)
                .frame(width: side, height: side)
                .overlay {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(Palette.secondaryText)
                }
                .accessibilityHidden(true)
        }
    }
}

// MARK: - About

/// About Tidykeep: what stays private, what the app can't do, the bundled privacy policy and
/// acknowledgements, the support address as plain text, and the version. No links.
struct AboutView: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Form {
            Section {
                header
                    .listRowBackground(Color.clear)
            }
            bullets(Copy.About.privacy, Copy.About.privacyBullets, tint: Palette.accent)
            bullets(Copy.About.cantDo, Copy.About.cantDoBullets, tint: Palette.secondaryText)
            Section {
                NavigationLink(value: Route.privacyPolicy) {
                    Label(Copy.About.privacyPolicy, systemImage: "hand.raised")
                }
                NavigationLink(value: Route.acknowledgements) {
                    Label(Copy.About.acknowledgements, systemImage: "doc.text")
                }
            } header: {
                Text(Copy.About.documents)
            }
            Section {
                Label {
                    Text(Copy.About.supportEmail)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "envelope")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Copy.About.supportLabel())
            } header: {
                Text(Copy.About.support)
            } footer: {
                Text(Copy.About.supportFooter)
            }
            Section {
                LabeledContent(Copy.Rules.version) {
                    Text(AppInfo.version).monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Copy.Rules.about)
        .inlineNavigationTitle()
    }

    /// The mark and name are the heading; the tagline and the Free line are read on their own,
    /// so the headings rotor lands on just the name.
    private var header: some View {
        VStack(spacing: Space.m) {
            VStack(spacing: Space.m) {
                AppMark(size: typeSize.isAccessibilitySize ? 64 : 76)
                Text(Copy.appName)
                    .font(.title2.bold())
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: Space.xs) {
                Text(Copy.About.tagline)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                Text(Copy.About.free)
                    .font(.subheadline.weight(.medium))
                    .padding(.top, Space.xs)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s)
    }

    private func bullets(_ title: String, _ items: [(symbol: String, text: String)], tint: Color) -> some View {
        Section {
            ForEach(items, id: \.text) { item in
                Label {
                    Text(item.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: item.symbol)
                        .foregroundStyle(tint)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(title)
        }
    }
}

// MARK: - Helpers

extension View {
    /// Buttons in a form row: the system row highlight on iPhone; plain on the Mac, whose
    /// forms would otherwise draw push buttons.
    @ViewBuilder
    func rowButtonStyle() -> some View {
        #if os(iOS)
        self
        #else
        buttonStyle(.plain)
        #endif
    }
}
