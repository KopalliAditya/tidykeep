import Accessibility
import Observation
import SwiftUI

/// Something just happened ("Moved 3 files to Holding."), with an optional way back.
struct Notice: Identifiable, Equatable {
    struct Undo {
        var title: String
        var action: @MainActor () async -> Void
    }

    let id = UUID()
    var text: String
    var systemImage: String
    var undo: Undo?

    static func == (a: Notice, b: Notice) -> Bool { a.id == b.id }
}

/// Shows notices and says things to VoiceOver. Shared by every part of the app, so only one
/// notice shows at a time and every result is announced the same way.
@MainActor
@Observable
public final class Notices {
    private(set) var current: Notice?

    public init() {}

    /// Shows a banner and announces it. High priority, so a screen change that often follows
    /// (a group closing after Remove) doesn't cut it off. Everything a banner says is also in
    /// History, so missing it loses nothing.
    func show(_ text: String, systemImage: String = "checkmark.circle", undo: Notice.Undo? = nil) {
        current = Notice(text: text, systemImage: systemImage, undo: undo)
        announce(text, priority: .high)
    }

    func dismiss(_ id: UUID? = nil) {
        if id == nil || current?.id == id { current = nil }
    }

    /// Says something without a banner, for changes the screen already shows.
    func announce(_ message: String, priority: AnnouncementPriority = .default) {
        var spoken = AttributedString(message)
        spoken.accessibilitySpeechAnnouncementPriority = priority
        AccessibilityNotification.Announcement(spoken).post()
    }

    /// The text of the latest notice, for tests and the UI tests' anchors.
    public var text: String? { current?.text }
}

typealias AnnouncementPriority = AttributeScopes.AccessibilityAttributes.AnnouncementPriorityAttribute.AnnouncementPriority

/// A glass capsule near the top of the screen. It hides itself after a few seconds, except
/// when VoiceOver or Switch Control is running: then it stays until dismissed. The text, Undo
/// and Dismiss are separate elements, read in that order.
struct NoticeBanner: View {
    @Environment(Notices.self) private var notices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let notice = notices.current {
                content(notice)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: notice.id) {
                        guard !Platform.assistiveTechRunning else { return }
                        try? await Task.sleep(for: .seconds(notice.undo == nil ? 4 : 6))
                        withAnimation(Motion.standard(reduceMotion)) { notices.dismiss(notice.id) }
                    }
            }
        }
        .animation(Motion.standard(reduceMotion), value: notices.current)
    }

    private func content(_ notice: Notice) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: notice.systemImage)
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("notice.banner")
            if let undo = notice.undo {
                Button(undo.title) {
                    notices.dismiss(notice.id)
                    Task { await undo.action() }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("notice.undo")
            }
            Button {
                notices.dismiss(notice.id)
            } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(Palette.secondaryText)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(Copy.General.dismiss)
        }
        .padding(.leading, Space.l)
        .padding(.trailing, Space.xs)
        .padding(.vertical, Space.xs)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, Space.l)
        .padding(.top, Space.s)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    func noticeOverlay() -> some View {
        overlay(alignment: .top) { NoticeBanner() }
    }
}
