import SwiftUI
import TidykeepCore

/// "What was checked": the photos looked at, and every reason others were skipped. Skipped
/// photos are never changed, so nothing here needs an action.
struct CoverageSheet: View {
    let coverage: Coverage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(Copy.Coverage.line(checked: coverage.checked, skipped: 0)) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                    }
                }
                Section {
                    ForEach(SkipReason.allCases) { reason in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            LabeledContent(Copy.Coverage.reason(reason)) {
                                Text((coverage.skipped[reason] ?? 0).formatted())
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.secondaryText)
                            }
                            .font(.body.weight(.medium))
                            Text(Copy.Coverage.explanation(reason))
                                .font(.footnote)
                                .foregroundStyle(Palette.secondaryText)
                        }
                        .padding(.vertical, Space.hair)
                        .accessibilityElement(children: .combine)
                    }
                } footer: {
                    Text(Copy.Coverage.footer).foregroundStyle(Palette.secondaryText)
                }
            }
            .groupedList()
            .navigationTitle(Copy.Coverage.title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.General.done) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
