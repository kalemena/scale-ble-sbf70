import Sbf70Kit
import SwiftUI

/// Live weigh-in: big weight readout, stable indicator, body-comp result.
struct LiveMeasureView: View {
    @EnvironmentObject private var session: SessionViewModel
    @EnvironmentObject private var appSettings: AppSettings
    @StateObject private var model = LiveMeasureViewModel()
    @State private var user: ScaleUser?

    var body: some View {
        List {
            if let uidHex = appSettings.activeUidHex {
                activeUserSection(uidHex: uidHex)
            } else {
                Section {
                    ContentUnavailableView(
                        "No Active User",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Pick a user in Settings or the Users tab.")
                    )
                }
            }
        }
        .navigationTitle("Measure")
        .task(id: appSettings.activeUidHex) {
            await loadUser()
        }
        .onChange(of: session.state) { _, state in
            if case .ready = state {
                Task { await loadUser() }
            }
        }
    }

    private func loadUser() async {
        guard let uidHex = appSettings.activeUidHex else {
            user = nil
            return
        }
        let users = (try? await JsonStore.shared.loadUsers()) ?? []
        user = users.first { $0.uidHex == uidHex }
    }

    @ViewBuilder
    private func activeUserSection(uidHex: String) -> some View {
        Section {
            HStack {
                Label(userDisplayName(uidHex), systemImage: "person")
                    .font(.subheadline)
                Spacer()
            }
        }

        Section {
            weightReadout

            if model.isMeasuring, model.result == nil {
                Label("Measuring body composition… keep standing still", systemImage: "waveform.path.ecg")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await model.measure(client: client, uidHex: uidHex) }
            } label: {
                if model.isMeasuring {
                    HStack {
                        ProgressView()
                        Text("Measuring…")
                    }
                } else {
                    Label("Start Measurement", systemImage: "play.circle")
                }
            }
            .disabled(model.isMeasuring)
        }

        if let result = model.result {
            resultSection(result)
        }

        if let error = model.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private var weightReadout: some View {
        VStack(spacing: 6) {
            if let kg = model.liveWeightKg {
                Text(String(format: "%.2f", kg))
                    .font(.system(size: 56, weight: .light, design: .rounded))
                    .monospacedDigit()
                Text(model.isStable ? "kg — stable" : "kg — settling…")
                    .font(.subheadline)
                    .foregroundStyle(model.isStable ? .green : .secondary)
            } else {
                Image(systemName: "figure.stand")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(model.isMeasuring ? "Step on the scale…" : "Ready")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func resultSection(_ result: ScaleMeasurement) -> some View {
        Section("Measurement") {
            metricRow(
                "Weight",
                icon: "scalemass.fill",
                value: String(format: "%.2f kg", result.weightKg),
                delta: delta(current: result.weightKg, previous: model.previous?.weightKg),
                decimals: 2,
                deltaColor: weightTrendColor(current: result.weightKg, delta: delta(current: result.weightKg, previous: model.previous?.weightKg))
            )
            bmiRow(result)
            metricRow(
                "Fat",
                icon: "pizza.slice",
                value: String(format: "%.1f %%", result.fatPct),
                delta: delta(current: result.fatPct, previous: model.previous?.fatPct)
            )
            metricRow(
                "Water",
                icon: "humidity.fill",
                value: String(format: "%.1f %%", result.waterPct),
                delta: delta(current: result.waterPct, previous: model.previous?.waterPct)
            )
            metricRow(
                "Muscle",
                icon: "dumbbell.fill",
                value: String(format: "%.1f %%", result.musclePct),
                delta: delta(current: result.musclePct, previous: model.previous?.musclePct)
            )
            metricRow(
                "Bone",
                icon: "figure.walk",
                value: String(format: "%.2f kg", result.boneKg),
                delta: delta(current: result.boneKg, previous: model.previous?.boneKg),
                decimals: 2
            )
            metricRow("Impedance", icon: "bolt.fill", value: "\(result.impedance) Ω")
            if model.saved {
                Label("Saved to history", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private func bmiRow(_ result: ScaleMeasurement) -> some View {
        let bmiInfo = bmiInfo(for: result)
        metricRow(
            "BMI",
            icon: bmiInfo.icon,
            value: bmiInfo.text,
            iconColor: bmiInfo.color,
            delta: delta(current: bmi(for: result), previous: model.previous.flatMap { bmi(for: $0) })
        )
    }

    private func bmiInfo(for measurement: ScaleMeasurement) -> BMIInfo {
        BMIInfo(bmi: bmi(for: measurement))
    }

    private func metricRow(
        _ label: String,
        icon: String,
        value: String,
        iconColor: Color = .secondary,
        delta: Double? = nil,
        decimals: Int = 1,
        deltaColor: Color = .secondary
    ) -> some View {
        MetricRow(
            label: label,
            icon: icon,
            value: value,
            iconColor: iconColor,
            delta: delta,
            decimals: decimals,
            deltaColor: deltaColor
        )
    }

    private func delta(current: Double?, previous: Double?) -> Double? {
        guard let current, let previous else { return nil }
        return current - previous
    }

    /// Green when the reading moved closer to the goal range, red when it
    /// moved away, and neutral while inside the range or without a goal.
    private func weightTrendColor(current: Double, delta: Double?) -> Color {
        guard let delta, let uidHex = appSettings.activeUidHex,
              let range = appSettings.goals[uidHex]?.weightRange else { return .secondary }
        let currentDistance = distance(from: current, to: range)
        if currentDistance == 0 { return .secondary }
        let previousDistance = distance(from: current - delta, to: range)
        return currentDistance < previousDistance ? .green : .red
    }

    /// Zero when inside the range, otherwise the distance to the nearest bound.
    private func distance(from weightKg: Double, to range: ClosedRange<Double>) -> Double {
        if weightKg < range.lowerBound { return range.lowerBound - weightKg }
        if weightKg > range.upperBound { return weightKg - range.upperBound }
        return 0
    }

    private var client: SBF70Client {
        // Safe: this view is only rendered while the session is ready.
        session.client!
    }

    /// e.g. "CLE (000065)" — shared display (see ScaleUser.displayName).
    private func userDisplayName(_ uidHex: String) -> String {
        if let user { return user.displayName }
        return String(uidHex.suffix(6)).uppercased()
    }

    private func bmi(for measurement: ScaleMeasurement) -> Double? {
        guard let heightCm = user?.heightCm, heightCm > 0 else { return nil }
        return HealthMetrics.bmi(weightKg: measurement.weightKg, heightCm: Double(heightCm))
    }
}

/// One measurement row: icon + label on the left, value on the right,
/// with an optional up/down trend arrow and delta before the value.
struct MetricRow: View {
    let label: String
    let icon: String
    let value: String
    var iconColor: Color = .secondary
    var delta: Double?
    var decimals: Int = 1
    var deltaColor: Color = .secondary

    init(
        label: String,
        icon: String,
        value: String,
        iconColor: Color = .secondary,
        delta: Double? = nil,
        decimals: Int = 1,
        deltaColor: Color = .secondary
    ) {
        self.label = label
        self.icon = icon
        self.value = value
        self.iconColor = iconColor
        self.delta = delta
        self.decimals = decimals
        self.deltaColor = deltaColor
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 24, alignment: .leading)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            Text(label)
            Spacer()
            if let delta, delta != 0 {
                HStack(spacing: 2) {
                    Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                        .accessibilityHidden(true)
                    Text(String(format: "%+.\(decimals)f", delta))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(deltaColor)
            }
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Icon, color, and formatted text for a BMI value.
struct BMIInfo {
    let icon: String
    let color: Color
    let text: String

    init(bmi: Double?) {
        guard let bmi else {
            icon = "gauge.with.dots.needle.50percent"
            color = .secondary
            text = "—"
            return
        }
        text = String(format: "%.1f", bmi)
        switch HealthMetrics.bmiStatus(bmi) {
        case .below:
            icon = "gauge.with.dots.needle.33percent"
            color = .orange
        case .ok:
            icon = "gauge.with.dots.needle.50percent"
            color = .green
        case .above:
            icon = "gauge.with.dots.needle.67percent"
            color = .red
        }
    }
}
