import Charts
import Sbf70Kit
import SwiftUI

/// Local measurement history with Swift Charts.
struct HistoryView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    @State private var measurements: [ScaleMeasurement] = []
    @State private var showFat = true
    @State private var showWater = false
    @State private var showMuscle = false
    @State private var exportURL: URL?

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
                        .swipeActions {
                            Button(role: .destructive) {
                                delete(measurement)
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
        let payload: [String: Any] = [
            "uid": uidHex,
            "measurements": measurements,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sbf70-history-\(uidHex).json")
        try? data.write(to: url, options: .atomic)
        return url
    }
}
