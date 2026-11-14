import SwiftUI
import TidykeepCore

/// Three tabs on the glass tab bar: Tidy, History and Rules. Each owns a navigation stack.
public struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("tab") private var tab: AppTab = .tidy
    @ViewState private var tidyPath: [Route] = []
    @ViewState private var historyPath: [Route] = []
    @ViewState private var rulesPath: [Route] = []

    public init() {}

    public var body: some View {
        @Bindable var state = state
        TabView(selection: $tab) {
            Tab(Copy.Tabs.tidy, systemImage: "sparkles.rectangle.stack", value: AppTab.tidy) {
                NavigationStack(path: $tidyPath) {
                    TidyHomeView().routes()
                }
            }
            .accessibilityIdentifier("tab.tidy")
            Tab(Copy.Tabs.history, systemImage: "clock.arrow.circlepath", value: AppTab.history) {
                NavigationStack(path: $historyPath) {
                    HistoryView().routes()
                }
            }
            .accessibilityIdentifier("tab.history")
            Tab(Copy.Tabs.rules, systemImage: "lock.shield", value: AppTab.rules) {
                NavigationStack(path: $rulesPath) {
                    RulesView().routes()
                }
            }
            .accessibilityIdentifier("tab.rules")
        }
        .minimizingTabBar()
        .tint(Palette.accent)
        .noticeOverlay()
        .contactsUndoConfirmation()
        .onboarding(isPresented: $state.showsOnboarding)
        .task { await state.start() }
        .onChange(of: scenePhase) { _, phase in state.scenePhaseChanged(to: phase) }
        .preferredColorScheme(state.appearance)
        .environment(state.photos)
        .environment(state.files)
        .environment(state.contacts)
        .environment(state.history)
        .environment(state.notices)
        .environment(state.preferences)
    }
}

extension View {
    /// Where every `Route` leads.
    func routes() -> some View {
        navigationDestination(for: Route.self) { RouteDestination(route: $0) }
    }
}

struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .similar: SimilarShotsView()
        case .similarGroup(let id): SimilarGroupView(groupID: id)
        case .copies: CopiesView()
        case .copySet(let id): CopySetView(groupID: id)
        case .screenshots: ScreenshotsView()
        case .videos: BigVideosView()
        case .video(let id): VideoDetailView(videoID: id)
        case .duplicateFiles: DuplicateFilesView()
        case .duplicateFileSet(let id): DuplicateFileSetView(setID: id)
        case .largeFiles: LargeFilesView()
        case .holding: HoldingView()
        case .contacts: DuplicateContactsView()
        case .contactMerge(let id): ContactMergeView(groupID: id)
        case .receipt(let id): ReceiptView(receiptID: id)
        case .albums: AlbumPickerView()
        case .about: AboutView()
        case .privacyPolicy: TextDocumentView(resource: "PrivacyPolicy", title: "Privacy Policy")
        case .acknowledgements: TextDocumentView(resource: "Acknowledgements", title: "Acknowledgements")
        }
    }
}
