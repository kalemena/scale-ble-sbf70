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
    private struct UserEntry: Identifiable {
        let uidHex: String
        let name: String
        let exportName: String
        let year: Int
        var id: String { uidHex }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var format: DataFormat = .json
    @State private var userEntries: [UserEntry] = []
    @State private var selectedUIDs: Set<String> = []
    @State private var measurementsByUID: [String: [ScaleMeasurement]] = [:]
    @State private var exportURL: URL?
    @State private var isLoading = true

    private var selectedEntries: [UserEntry] {
        userEntries.filter { selectedUIDs.contains($0.uidHex) }
    }

    private var selectedMeasurements: [ScaleMeasurement] {
        selectedEntries
            .flatMap { measurementsByUID[$0.uidHex] ?? [] }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var selectionSummary: String {
        guard !userEntries.isEmpty else { return "None" }
        if selectedUIDs.isEmpty { return "None" }
        if selectedUIDs.count == userEntries.count { return "All (\(userEntries.count))" }
        return "\(selectedUIDs.count) of \(userEntries.count)"
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
                Section("Users") {
                    if isLoading {
                        ProgressView()
                    } else if userEntries.isEmpty {
                        Text("No users available.")
                            .foregroundStyle(.secondary)
                    } else {
                        Menu {
                            ForEach(userEntries) { entry in
                                Button {
                                    toggle(entry.uidHex)
                                } label: {
                                    if selectedUIDs.contains(entry.uidHex) {
                                        Label(entry.name, systemImage: "checkmark")
                                    } else {
                                        Text(entry.name)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text("Users")
                                Spacer()
                                Text(selectionSummary)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
            .onChange(of: format) { _, _ in refreshExportURL() }
            .onChange(of: selectedUIDs) { _, _ in refreshExportURL() }
        }
    }

    private func toggle(_ uidHex: String) {
        if selectedUIDs.contains(uidHex) {
            selectedUIDs.remove(uidHex)
        } else {
            selectedUIDs.insert(uidHex)
        }
    }

    /// Load fresh from disk when the dialog opens so it never depends on a
    /// possibly stale in-memory active user.
    private func load() async {
        let counts = (try? await JsonStore.shared.allMeasurementCounts()) ?? [:]
        let users = (try? await JsonStore.shared.loadUsers()) ?? []

        var entries: [UserEntry] = []
        var loaded: [String: [ScaleMeasurement]] = [:]
        let allUIDs = Set(users.map(\.uidHex)).union(counts.keys)
        for uidHex in allUIDs.sorted() {
            let measurements = (try? await JsonStore.shared.loadMeasurements(uidHex: uidHex)) ?? []
            let user = users.first { $0.uidHex == uidHex }
            let fallbackName = measurements.compactMap(\.userName).first ?? ""
            let name = user?.name ?? fallbackName
            let display = user?.displayName
                ?? (name.isEmpty
                    ? "uid \(uidHex.suffix(6))"
                    : "\(name.uppercased()) (\(uidHex.suffix(6).uppercased()))")
            entries.append(UserEntry(
                uidHex: uidHex,
                name: display,
                exportName: name,
                year: user?.year ?? 0
            ))
            loaded[uidHex] = measurements
        }

        userEntries = entries
        measurementsByUID = loaded
        selectedUIDs = Set(entries.map(\.uidHex))
        isLoading = false
        refreshExportURL()
    }

    private func refreshExportURL() {
        let measurements = selectedMeasurements
        guard !measurements.isEmpty else {
            exportURL = nil
            return
        }
        switch format {
        case .json:
            exportURL = Self.jsonURL(users: selectedEntries, measurements: measurements)
        case .csv:
            exportURL = Self.csvURL(measurements: measurements)
        }
    }

    /// CSV export matching CLI measurement fields (snake_case via CodingKeys).
    private static func csvURL(measurements: [ScaleMeasurement]) -> URL? {
        // Header: timestamp,time_iso,weight_kg,impedance,fat_pct,water_pct,muscle_pct,bone_kg,uid,user_name
        var csv = "timestamp,time_iso,weight_kg,impedance,fat_pct,water_pct,muscle_pct,bone_kg,uid,user_name\n"
        for m in measurements {
            let uid = m.uid ?? ""
            let user = m.userName ?? ""
            csv += "\(m.timestamp),\(m.timeISO),\(m.weightKg),\(m.impedance),\(m.fatPct),\(m.waterPct),\(m.musclePct),\(m.boneKg),\(uid),\(user)\n"
        }
        let data = Data(csv.utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(for: measurements, ext: "csv"))
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// CLI-compatible JSON for piping into tools/measurements-report.py.
    private static func jsonURL(users: [UserEntry], measurements: [ScaleMeasurement]) -> URL? {
        // JSONEncoder, not JSONSerialization: the latter rejects Swift structs
        // boxed as __SwiftValue ("Invalid type in JSON write").
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = CLIExportPayload(
            users: users.map {
                CLIExportPayload.User(uid: $0.uidHex, name: $0.exportName, year: $0.year)
            },
            measurements: measurements
        )
        guard let data = try? encoder.encode(payload) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(for: measurements, ext: "json"))
        try? data.write(to: url, options: .atomic)
        return url
    }

    private static func fileName(for measurements: [ScaleMeasurement], ext: String) -> String {
        let uids = Set(measurements.compactMap(\.uid))
        if uids.count == 1, let uid = uids.first {
            return "sbf70-history-\(uid).\(ext)"
        }
        return "sbf70-history.\(ext)"
    }
}

/// Matches `sbf70.py history` JSON output shape (keys come from CodingKeys).
private struct CLIExportPayload: Encodable {
    struct User: Encodable {
        let uid: String
        let name: String
        let year: Int
    }

    let users: [User]
    let measurements: [ScaleMeasurement]
}
