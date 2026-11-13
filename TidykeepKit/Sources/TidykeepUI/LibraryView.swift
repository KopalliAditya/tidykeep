import TidykeepCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The main screen: scan status, then every group to review.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var showSettings = false
    @ViewState private var confirmRemoveAll = false
    @ViewState private var path: [String] = []
    @ViewState private var openedIndex = 0
    @AccessibilityFocusState private var focusedGroup: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section { ScanStatusCard() }
                if model.access == .limited {
                    Section { LimitedAccessNote() }
                }
                if !model.groups.isEmpty {
                    Section {
                        ForEach(model.groups) { group in
                            NavigationLink(value: group.id) { GroupRow(group: group) }
                                .accessibilityFocused($focusedGroup, equals: group.id)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) { GroupRowActions(group: group) }
                        }
                    } header: {
                        Text("To review")
                    }
                } else if case .finished = model.scanState {
                    Section { EmptyState() }
                }
            }
            .navigationTitle(AppInfo.name)
            .navigationDestination(for: String.self) { GroupDetailView(groupID: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .refreshable { model.rescan() }
            .onChange(of: path) { old, new in
                if let opened = new.last {
                    openedIndex = model.groups.firstIndex { $0.id == opened } ?? 0
                } else if let closed = old.last, model.group(closed) == nil, !model.groups.isEmpty {
                    // The group was removed or kept whole. Put VoiceOver on the next one instead
                    // of the top of the screen, once the pop has settled.
                    let next = model.groups[min(openedIndex, model.groups.count - 1)].id
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        focusedGroup = next
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                let count = model.suggestedRemovalCount
                if count > 0 {
                    Button {
                        confirmRemoveAll = true
                    } label: {
                        Label("Remove \(Copy.photos(count))", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isDeleting)
                    .accessibilityHint("Removes every photo marked for removal, in all groups")
                    .padding()
                    .background(.bar)
                }
            }
            .confirmationDialog(
                "Remove \(Copy.photos(model.suggestedRemovalCount)) from \(Copy.groups(model.groups.count { !model.removals(in: $0).isEmpty }))?",
                isPresented: $confirmRemoveAll,
                titleVisibility: .visible
            ) {
                Button("Remove \(Copy.photos(model.suggestedRemovalCount))", role: .destructive) {
                    Task { await model.removeAllSuggested() }
                }
            } message: {
                Text("Photos you chose to keep stay. Removed photos go to Recently Deleted in Photos for 30 days.")
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}

struct ScanStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.scanState {
            case .idle:
                Label("Ready to look for similar photos", systemImage: "sparkle.magnifyingglass")
                Button("Start looking") { model.rescan() }
            case .scanning(let p):
                Label("Looking for similar photos", systemImage: "sparkle.magnifyingglass").font(.headline)
                ProgressView(value: p.fraction)
                    .accessibilityLabel("Scan progress")
                    .accessibilityValue(Copy.checked(p))
                Text("\(Copy.checked(p)) · groups appear as they're found")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button("Stop looking") { model.stopScan() }
            case .paused:
                Label("Paused while your phone cools down", systemImage: "thermometer.medium").font(.headline)
                Text("It picks up again on its own.").font(.footnote).foregroundStyle(.secondary)
            case .stopped:
                Label("Stopped", systemImage: "pause.circle").font(.headline)
                Text("Groups found so far are below.").font(.footnote).foregroundStyle(.secondary)
                Button("Keep looking") { model.rescan() }
            case .finished(let p, let date):
                Text(Copy.scanSummary(groups: model.groups.count, extras: model.suggestedRemovalCount)).font(.headline)
                Text("\(model.scope.title) · checked \(date.formatted(.relative(presentation: .named)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if p.skipped > 0 {
                    Text(Copy.skipped(p.skipped)).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Check again") { model.rescan() }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                Button("Try again") { model.rescan() }
            }
        }
        // In a List row, a default-style button takes taps anywhere in the row.
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
    }
}

struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: PhotoGroup

    var body: some View {
        let removing = model.removals(in: group).count
        let kept = group.members.count - removing
        HStack(spacing: 14) {
            ThumbnailStack(group: group)
            VStack(alignment: .leading, spacing: 3) {
                Text(Copy.groupTitle(group)).font(.headline)
                Text(group.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Copy.keepRemove(kept: kept, removing: removing)).font(.subheadline)
                if group.ranking.isCloseCall {
                    Label {
                        Text("Close call")
                    } icon: {
                        Image(systemName: "eye").foregroundStyle(.orange)
                    }
                    .font(.caption.weight(.medium))
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.groupLabel(group, kept: kept, removing: removing))
        .accessibilityHint("Opens the group to review")
    }
}

/// Keep or clean up a group from the list. VoiceOver lists these as actions on the row.
struct GroupRowActions: View {
    @Environment(AppModel.self) private var model
    let group: PhotoGroup

    var body: some View {
        let removing = model.removals(in: group).count
        if removing > 0 {
            Button {
                Task { await model.removeSuggested(in: group) }
            } label: {
                Label("Remove \(Copy.photos(removing))", systemImage: "trash")
            }
            .tint(.red)
            .disabled(model.isDeleting)
        }
        Button {
            model.keepAll(group)
        } label: {
            Label("Keep all", systemImage: "checkmark")
        }
        .tint(.accentColor)
    }
}

/// The keeper in front, two more fanned out behind it.
struct ThumbnailStack: View {
    let group: PhotoGroup
    private let side: CGFloat = 64

    var body: some View {
        ZStack {
            ForEach(Array(group.members.prefix(3).enumerated().reversed()), id: \.element.id) { index, meta in
                PhotoThumbnail(id: meta.id, pixelSize: 260)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.background, lineWidth: 2))
                    .rotationEffect(.degrees(Double(index) * 6))
                    .offset(x: CGFloat(index) * 5)
            }
        }
        .frame(width: side + 12, height: side + 8)
        .accessibilityHidden(true)
    }
}

struct LimitedAccessNote: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 8) {
                Text("Only photos you picked").font(.headline)
                Text("\(AppInfo.name) can see just the photos you chose. To check them all, open Settings, tap Photos, then Full Access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Choose photos") { Task { await model.chooseMorePhotos() } }
                #if os(iOS)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                #endif
            }
            .buttonStyle(.borderless)
        } icon: {
            Image(systemName: "photo.badge.checkmark")
        }
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.largeTitle)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Nothing to clean up").font(.headline)
            Text("No runs of near-identical photos in this range. Try All photos in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
        .accessibilityElement(children: .combine)
    }
}
