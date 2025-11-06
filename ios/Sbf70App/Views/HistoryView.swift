import Charts
import Sbf70Kit
import SwiftUI

/// Local measurement history with Swift Charts.
struct HistoryView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var session: SessionViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var measurements: [ScaleMeasurement] = []
    @State private var showFat = true
    @State private var showWater = false
    @State private var showMuscle = false
    @State private var exportURL: URL?
    @State private var pendingDeletion: ScaleMeasurement?
    @State private var detailMeasurement: ScaleMeasurement?
    @State private var usersByUID: [String: ScaleUser] = [:]
    @State private var showSync = false

    var body: some View {
        NavigationStack {
            Group {
                if measurements.isEmpty {
                    ContentUnavailableView(
                        "No Measurements",
                        systemImage: "chart.line.downtrend.xyaxis",
                        description: Text("Sync from the scale or import a CLI export in Settings.")
                    )
                } else {
                    chartAndList
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showSync = true
                        } label: {
                            Label("Sync from Scale", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(session.client == nil || appSettings.activeUidHex == nil)

                        if let url = shareURL {
                            ShareLink(item: url) {
                                Label("Export JSON", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .task { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await reload() }
            }
        }
        .onChange(of: appSettings.activeUidHex) { _, _ in
            Task { await reload() }
        }
        .confirmationDialog(
            "Delete measurement?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { measurement in
            Button("Delete", role: .destructive) {
                delete(measurement)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { measurement in
            Text(
                "\(measurement.date.formatted(date: .abbreviated, time: .shortened)) · "
                    + String(format: "%.2f kg", measurement.weightKg)
                    + " will be removed from this device."
            )
        }
        .sheet(item: $detailMeasurement) { measurement in
            MeasurementDetailSheet(
                measurement: measurement,
                userName: usersByUID[measurement.uid ?? ""]?.name
            )
        }
        .sheet(isPresented: $showSync) {
            SyncView()
        }
    }

    private var chartAndList: some View {
        List {
            Section {
                chart
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))

                HStack(spacing: 12) {
                    toggleChip("Weight", isOn: .constant(true), color: .blue)
                    toggleChip("Fat %", isOn: $showFat, color: .orange)
                    toggleChip("Water %", isOn: $showWater, color: .cyan)
                    toggleChip("Muscle %", isOn: $showMuscle, color: .green)
                }
                .font(.caption)
            }

            Section("\(measurements.count) readings") {
                ForEach(measurements.reversed()) { measurement in
                    row(measurement)
                        .contentShape(Rectangle())
                        .onLongPressGesture {
                            detailMeasurement = measurement
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletion = measurement
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    private var chart: some View {
        Chart(measurements) { m in
            LineMark(x: .value("Date", m.date), y: .value("Weight", m.weightKg))
                .foregroundStyle(.blue)
                .interpolationMethod(.monotone)
            PointMark(x: .value("Date", m.date), y: .value("Weight", m.weightKg))
                .foregroundStyle(.blue)

            if showFat {
                LineMark(x: .value("Date", m.date), y: .value("Fat %", m.fatPct), series: .value("Metric", "Fat %"))
                    .foregroundStyle(.orange)
                    .interpolationMethod(.monotone)
            }
            if showWater {
                LineMark(x: .value("Date", m.date), y: .value("Water %", m.waterPct), series: .value("Metric", "Water %"))
                    .foregroundStyle(.cyan)
                    .interpolationMethod(.monotone)
            }
            if showMuscle {
                LineMark(x: .value("Date", m.date), y: .value("Muscle %", m.musclePct), series: .value("Metric", "Muscle %"))
                    .foregroundStyle(.green)
                    .interpolationMethod(.monotone)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
    }

    private func toggleChip(_ label: String, isOn: Binding<Bool>, color: Color) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Label(label, systemImage: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn.wrappedValue ? color : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func row(_ m: ScaleMeasurement) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(m.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.2f kg", m.weightKg))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }
            Text(String(format: "fat %.1f%% · water %.1f%% · muscle %.1f%% · Z %dΩ", m.fatPct, m.waterPct, m.musclePct, m.impedance))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func reload() async {
        guard let uidHex = appSettings.activeUidHex else {
            measurements = []
            return
        }
        measurements = (try? await JsonStore.shared.loadMeasurements(uidHex: uidHex)) ?? []
        let users = (try? await JsonStore.shared.loadUsers()) ?? []
        usersByUID = Dictionary(uniqueKeysWithValues: users.map { ($0.uidHex, $0) })
    }

    private func delete(_ m: ScaleMeasurement) {
        guard let uidHex = appSettings.activeUidHex else { return }
        Task {
            try? await JsonStore.shared.deleteMeasurement(uidHex: uidHex, timestamp: m.timestamp)
            await reload()
        }
    }

    /// CLI-compatible JSON for piping into tools/measurements-report.py.
    private var shareURL: URL? {
        guard !measurements.isEmpty, let uidHex = appSettings.activeUidHex else { return nil }
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

/// Long-press detail sheet: every field stored for one reading.
private struct MeasurementDetailSheet: View {
    let measurement: ScaleMeasurement
    let userName: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Date") {
                    LabeledContent("Local", value: measurement.date.formatted(date: .complete, time: .standard))
                }
                Section("Body") {
                    LabeledContent("Weight", value: String(format: "%.2f kg", measurement.weightKg))
                    LabeledContent("Impedance", value: "\(measurement.impedance) Ω")
                    LabeledContent("Fat", value: String(format: "%.1f %%", measurement.fatPct))
                    LabeledContent("Water", value: String(format: "%.1f %%", measurement.waterPct))
                    LabeledContent("Muscle", value: String(format: "%.1f %%", measurement.musclePct))
                    LabeledContent("Bone", value: String(format: "%.2f kg", measurement.boneKg))
                }
                Section("User") {
                    LabeledContent("User", value: userLabel)
                }
            }
            .navigationTitle("Measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// e.g. "0000000000000065 · CLE" — scale stores 3-letter nicknames.
    private var userLabel: String {
        let uid = measurement.uid ?? measurement.userName ?? "—"
        guard let name = userName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return uid
        }
        return "\(uid) · \(name.uppercased())"
    }
}
