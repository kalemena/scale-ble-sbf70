import Sbf70Kit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var session: SessionViewModel
    @EnvironmentObject private var appSettings: AppSettings
    @State private var users: [ScaleUser] = []
    @State private var counts: [String: Int] = [:]
    @State private var showImportDialog = false
    @State private var showExportDialog = false
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
        .onAppear { Task { await reload() } }
        .onChange(of: appSettings.activeUidHex) { _, _ in
            Task { await reload() }
        }
        .sheet(isPresented: $showImportDialog) {
            ImportDialog { format, url in
                Task { await importFile(format: format, at: url) }
            }
        }
        .sheet(isPresented: $showExportDialog) {
            ExportDialog()
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
            Button("Export") {
                showExportDialog = true
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

    private func importFile(format: DataFormat, at url: URL) async {
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

// MARK: - Import / export formats

enum DataFormat: String, CaseIterable, Identifiable {
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

// MARK: - Import dialog

private struct ImportDialog: View {
    let onImport: (DataFormat, URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var format: DataFormat = .json
    @State private var selectedFile: URL?
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(DataFormat.allCases) { format in
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

// MARK: - Export dialog

private struct ExportDialog: View {
    @Environment(\.dismiss) private var dismiss
    @State private var format: DataFormat = .json
    @State private var measurements: [ScaleMeasurement] = []
    @State private var uidHex: String?
    @State private var userName: String?
    @State private var isLoading = true

    private var exportURL: URL? {
        guard !measurements.isEmpty, let uidHex else { return nil }
        switch format {
        case .json:
            return Self.jsonURL(uidHex: uidHex, measurements: measurements)
        case .csv:
            return Self.csvURL(uidHex: uidHex, measurements: measurements)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(DataFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section("User") {
                    if isLoading {
                        ProgressView()
                    } else if let uidHex {
                        LabeledContent("User", value: userName ?? "uid \(uidHex.suffix(6))")
                    } else {
                        Text("No user with measurements.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Export \(format.title)", systemImage: "square.and.arrow.up")
                        }
                    } else if !isLoading {
                        Text("No measurements to export.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    /// Load fresh from disk when the dialog opens so it never depends on a
    /// possibly stale in-memory active user.
    private func load() async {
        let counts = (try? await JsonStore.shared.allMeasurementCounts()) ?? [:]
        let settings = (try? await JsonStore.shared.loadSettings()) ?? .init()

        let preferred = settings.activeUidHex
        let uid: String?
        if let preferred, (counts[preferred] ?? 0) > 0 {
            uid = preferred
        } else {
            uid = counts.keys.sorted().first
        }

        uidHex = uid
        if let uid {
            measurements = (try? await JsonStore.shared.loadMeasurements(uidHex: uid)) ?? []
            let users = (try? await JsonStore.shared.loadUsers()) ?? []
            userName = users.first { $0.uidHex == uid }?.displayName
        } else {
            measurements = []
            userName = nil
        }
        isLoading = false
    }

    /// CSV export matching CLI measurement fields (snake_case via CodingKeys).
    private static func csvURL(uidHex: String, measurements: [ScaleMeasurement]) -> URL? {
        // Header: timestamp,time_iso,weight_kg,impedance,fat_pct,water_pct,muscle_pct,bone_kg,uid,user_name
        var csv = "timestamp,time_iso,weight_kg,impedance,fat_pct,water_pct,muscle_pct,bone_kg,uid,user_name\n"
        for m in measurements {
            let uid = m.uid ?? ""
            let user = m.userName ?? ""
            csv += "\(m.timestamp),\(m.timeISO),\(m.weightKg),\(m.impedance),\(m.fatPct),\(m.waterPct),\(m.musclePct),\(m.boneKg),\(uid),\(user)\n"
        }
        let data = Data(csv.utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sbf70-history-\(uidHex).csv")
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// CLI-compatible JSON for piping into tools/measurements-report.py.
    private static func jsonURL(uidHex: String, measurements: [ScaleMeasurement]) -> URL? {
        // JSONEncoder, not JSONSerialization: the latter rejects Swift structs
        // boxed as __SwiftValue ("Invalid type in JSON write").
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(CLIExportPayload(uid: uidHex, measurements: measurements)) else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sbf70-history-\(uidHex).json")
        try? data.write(to: url, options: .atomic)
        return url
    }
}

/// Matches `sbf70.py history` JSON output shape (keys come from CodingKeys).
private struct CLIExportPayload: Encodable {
    let uid: String
    let measurements: [ScaleMeasurement]
}
