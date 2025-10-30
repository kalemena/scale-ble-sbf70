import Sbf70Kit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: SessionViewModel
    @EnvironmentObject private var appSettings: AppSettings
    @State private var users: [ScaleUser] = []
    @State private var counts: [String: Int] = [:]
    @State private var showImporter = false
    @State private var importResult: String?
    @State private var showWipeConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                userSection
                syncSection
                dataSection
                aboutSection
            }
            .navigationTitle("Settings")
        }
        .task { await reload() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                Task { await importFile(at: url) }
            case .failure:
                importResult = "Import failed."
            }
        }
        .confirmationDialog("Wipe all local data?", isPresented: $showWipeConfirm, titleVisibility: .visible) {
            Button("Wipe", role: .destructive) {
                Task {
                    try? await JsonStore.shared.wipeAllData()
                    await appSettings.load()
                    await reload()
                    importResult = "Local data wiped."
                }
            }
        } message: {
            Text("Measurements, users cache and settings stored in this app will be deleted. Nothing on the scale changes.")
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            if let name = session.deviceName ?? appSettings.settings.lastDeviceName {
                LabeledContent("Device", value: name)
            }
            if let uuid = appSettings.settings.lastPeripheralUUID {
                LabeledContent("Last seen") {
                    Text(uuid)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if session.isReady {
                Button("Disconnect", role: .destructive) {
                    session.disconnect()
                }
            } else {
                Text("Not connected — connect from the Measure tab.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var userSection: some View {
        Section("Active user") {
            if users.isEmpty {
                Text("No cached users. Connect the scale and open the Users tab.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker("User", selection: Binding(
                    get: { appSettings.settings.activeUidHex ?? users.first?.uidHex ?? "" },
                    set: { newValue in
                        appSettings.settings.activeUidHex = newValue
                        Task { await appSettings.save() }
                    }
                )) {
                    ForEach(users) { user in
                        Text("\(user.name) · \(user.year)").tag(user.uidHex)
                    }
                }
            }
        }
    }

    private var syncSection: some View {
        Section("Sync") {
            Toggle(isOn: Binding(
                get: { appSettings.settings.deleteAfterSync },
                set: { newValue in
                    appSettings.settings.deleteAfterSync = newValue
                    Task { await appSettings.save() }
                }
            )) {
                Text("Delete readings from scale after sync")
            }
        }
    }

    private var dataSection: some View {
        Section("Data") {
            if !counts.isEmpty {
                ForEach(counts.keys.sorted(), id: \.self) { uid in
                    LabeledContent("uid \(uid.suffix(6))", value: "\(counts[uid] ?? 0) readings")
                }
            }
            Button("Import CLI export (history JSON)…") {
                showImporter = true
            }
            if let importResult {
                Text(importResult)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Wipe local data…", role: .destructive) {
                showWipeConfirm = true
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            Text("iOS client for the Sanitas SBF70 / Beurer BF710 family, ported from the Python CLI in tools/sbf70-cli. Protocol: openScale BeurerSanitasHandler.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func reload() async {
        users = (try? await JsonStore.shared.loadUsers()) ?? []
        counts = (try? await JsonStore.shared.allMeasurementCounts()) ?? [:]
    }

    private func importFile(at url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            importResult = "Cannot access the selected file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let results = try await JsonStore.shared.importCLIExport(data)
            await appSettings.load()
            await reload()
            let total = results.values.reduce(0) { $0 + $1.inserted + $1.updated }
            importResult = "Imported \(total) measurement(s) across \(results.count) user(s)."
        } catch {
            importResult = "Import failed: \(error.localizedDescription)"
        }
    }
}
