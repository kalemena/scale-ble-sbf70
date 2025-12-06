import Sbf70Kit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var session: SessionViewModel
    @EnvironmentObject private var appSettings: AppSettings
    @State private var users: [ScaleUser] = []
    @State private var counts: [String: Int] = [:]
    @State private var showImportDialog = false
    @State private var importResult: String?
    @State private var showWipeConfirm = false

    var body: some View {
        NavigationStack {
            Form {
            connectionSection
            syncSection
                dataSection
                aboutSection
            }
            .navigationTitle("Settings")
        }
        .task { await reload() }
        .sheet(isPresented: $showImportDialog) {
            ImportDialog { format, url in
                Task { await importFile(format: format, at: url) }
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
            Button("Import") {
                showImportDialog = true
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

    private func importFile(format: ImportFormat, at url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            importResult = "Cannot access the selected file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let results: [String: (inserted: Int, updated: Int)]
            switch format {
            case .json:
                results = try await JsonStore.shared.importCLIExport(data)
            case .csv:
                results = try await JsonStore.shared.importCSV(data)
            }
            await appSettings.load()
            await reload()
            let total = results.values.reduce(0) { $0 + $1.inserted + $1.updated }
            importResult = "Imported \(total) measurement(s) across \(results.count) user(s)."
        } catch {
            importResult = "Import failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Import dialog

enum ImportFormat: String, CaseIterable, Identifiable {
    case json
    case csv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .json: return "JSON"
        case .csv: return "CSV"
        }
    }

    var contentType: UTType {
        switch self {
        case .json: return .json
        case .csv: return .commaSeparatedText
        }
    }
}

private struct ImportDialog: View {
    let onImport: (ImportFormat, URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var format: ImportFormat = .json
    @State private var selectedFile: URL?
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(ImportFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section("File") {
                    Button {
                        showImporter = true
                    } label: {
                        if let selectedFile {
                            HStack {
                                Text("File")
                                Spacer()
                                Text(selectedFile.lastPathComponent)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } else {
                            Text("Choose file…")
                        }
                    }
                }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        if let selectedFile {
                            onImport(format, selectedFile)
                        }
                        dismiss()
                    }
                    .disabled(selectedFile == nil)
                }
            }
            .onChange(of: format) { _, _ in
                selectedFile = nil
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [format.contentType]
            ) { result in
                if case let .success(url) = result {
                    selectedFile = url
                }
            }
        }
    }
}
