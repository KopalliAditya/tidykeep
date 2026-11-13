import GoodTakeCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Photos from", selection: Binding(get: { model.scope }, set: { model.setScope($0) })) {
                        ForEach(ScanScope.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("How alike", selection: Binding(get: { model.sensitivity }, set: { model.setSensitivity($0) })) {
                        ForEach(Sensitivity.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("What to look at")
                } footer: {
                    Text("Changing these checks your photos again. Photos already analyzed aren't analyzed twice, so it's quick.")
                }

                Section("Privacy") {
                    Label("Everything happens on this phone", systemImage: "lock.shield")
                    Text("\(AppInfo.name) has no account, no ads and no analytics, and it makes no network requests. It never downloads photos from iCloud.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Safety") {
                    Text("Favorites, edited photos and documents are always kept. Every group keeps at least one photo. Removed photos go to Recently Deleted in Photos for 30 days.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Photos removed so far", value: "\(model.ledger.photosRemoved)")
                    Button("Show groups I kept") { model.restoreKeptGroups() }
                        .disabled(model.ledger.dismissedGroups.isEmpty)
                    Button("Forget saved analysis", role: .destructive) { confirmForget = true }
                }

                Section {
                    LabeledContent("Version", value: AppInfo.version)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Forget saved analysis?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget and check again", role: .destructive) {
                    Task { await model.forgetAnalysis() }
                }
            } message: {
                Text("Your photos aren't touched. \(AppInfo.name) analyzes them again from scratch.")
            }
        }
    }
}
