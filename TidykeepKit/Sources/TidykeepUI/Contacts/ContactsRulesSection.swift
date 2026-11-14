import SwiftUI

/// The Contacts part of Rules, for a `Form`: access, what the app can't know about My Card,
/// the saved backups, and cards kept apart.
struct ContactsRulesSection: View {
    @Environment(ContactsModel.self) private var contacts
    @ViewState private var confirmingDelete = false
    @ViewState private var isAsking = false

    var body: some View {
        Section {
            LabeledContent(Copy.Contacts.accessTitle, value: Copy.Contacts.accessValue(contacts.access, limited: contacts.isLimited, restricted: contacts.isRestricted))
                .accessibilityIdentifier("rules.contacts.access")
            accessButton
            Label {
                Text(Copy.Contacts.myCard)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(Palette.accent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("rules.contacts.mycard")
            LabeledContent(Copy.Contacts.backups, value: Copy.Contacts.backupCount(contacts.backupCount))
                .accessibilityIdentifier("rules.contacts.backups")
            if contacts.backupCount > 0 {
                Button(Copy.Contacts.deleteBackups, role: .destructive) { confirmingDelete = true }
                    .rowButtonStyle()
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("rules.contacts.deleteBackups")
                    .confirmationDialog(Copy.Contacts.deleteBackupsTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button(Copy.Contacts.deleteBackups, role: .destructive) { contacts.deleteBackups() }
                        Button(Copy.General.cancel, role: .cancel) {}
                    } message: {
                        Text(Copy.Contacts.deleteBackupsMessage)
                    }
            }
            if !contacts.keptApart.isEmpty {
                LabeledContent(Copy.Contacts.keptApartTitle, value: Copy.Contacts.groups(contacts.keptApart.count))
                    .accessibilityIdentifier("rules.contacts.keptApart")
                Button(Copy.Contacts.suggestAgain) { contacts.suggestAgain() }
                    .rowButtonStyle()
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("rules.contacts.suggestAgain")
            }
        } header: {
            Text(Copy.Contacts.rulesTitle)
        } footer: {
            Text(Copy.Contacts.rulesFooter)
        }
    }

    @ViewBuilder
    private var accessButton: some View {
        switch contacts.access {
        case .notDetermined:
            Button(Copy.Home.allowContacts) {
                isAsking = true
                Task {
                    await contacts.requestAccess()
                    isAsking = false
                }
            }
            .disabled(isAsking)
            .rowButtonStyle()
            .frame(minHeight: 44)
            .accessibilityIdentifier("rules.contacts.allow")
        case .denied:
            // Restricted access can't be turned on in Settings.
            if Platform.canOpenSettings, !contacts.isRestricted {
                Button(Copy.General.openSettings) { Platform.openSettings() }
                    .rowButtonStyle()
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("rules.contacts.settings")
            }
        case .allowed:
            EmptyView()
        }
    }
}
