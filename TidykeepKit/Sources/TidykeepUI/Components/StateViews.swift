import SwiftUI
import TidykeepCore

/// The empty state of every list: "All tidy". Also the UI tests' anchor.
struct AllTidyView: View {
    var detail: String?

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Palette.accent)
                .symbolEffect(.bounce, options: .nonRepeating)
                .accessibilityHidden(true)
            Text(Copy.Empty.allTidy)
                .font(.title2.weight(.semibold))
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Access is off: says what that means and offers Settings. Never a dead end; the other areas
/// still work.
struct AccessOffView: View {
    let title: String
    let detail: String
    var symbol = "lock"
    /// Shown instead of Open Settings when the app may still ask.
    var ask: (title: String, action: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                Image(systemName: symbol)
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text(title).font(.headline)
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let ask {
                Button(ask.title, action: ask.action)
                    .prominentGlassButton()
                    .foregroundStyle(Palette.onAccent)
            } else if Platform.canOpenSettings {
                Button(Copy.General.openSettings) { Platform.openSettings() }
                    .buttonStyle(.glass)
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// An error in place, next to what failed, with a way forward.
struct InlineError: View {
    let text: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let retry {
                Button(Copy.General.tryAgain, action: retry)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(Space.m)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Where the photo check is: a progress bar with "1,204 of 2,814 checked", and the reminder to
/// keep the app open. Hidden when the check is done.
struct ScanStatusView: View {
    let state: PhotosModel.ScanState

    var body: some View {
        switch state {
        case .scanning(let p), .paused(let p):
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Text(isPaused ? Copy.Scan.paused : Copy.Scan.progress(p))
                        .font(.subheadline.weight(.medium))
                        .contentTransition(.numericText())
                    Spacer()
                    if !isPaused { ProgressView().controlSize(.small) }
                }
                ProgressView(value: p.photosInRange == 0 ? 0 : Double(p.checked), total: Double(max(p.photosInRange, 1)))
                    .tint(Palette.accent)
                Text(Copy.Scan.keepOpen)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.l)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("scan.status")
        case .stopped:
            InlineError(text: Copy.Scan.stopped)
        case .failed:
            InlineError(text: Copy.Scan.failed)
        case .idle, .finished:
            EmptyView()
        }
    }

    private var isPaused: Bool {
        if case .paused = state { true } else { false }
    }
}
