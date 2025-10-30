import Sbf70Kit
import SwiftUI

/// Live weigh-in: big weight readout, stable indicator, body-comp result.
struct LiveMeasureView: View {
    @EnvironmentObject private var session: SessionViewModel
    @EnvironmentObject private var appSettings: AppSettings
    @StateObject private var model = LiveMeasureViewModel()

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
    }

    @ViewBuilder
    private func activeUserSection(uidHex: String) -> some View {
        Section {
            HStack {
                Label("User \(uidHex.suffix(4))", systemImage: "person")
                    .font(.subheadline)
                Spacer()
                Text("uid \(uidHex)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
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
            metricRow("Weight", value: String(format: "%.2f kg", result.weightKg))
            metricRow("Impedance", value: "\(result.impedance) Ω")
            metricRow("Fat", value: String(format: "%.1f %%", result.fatPct))
            metricRow("Water", value: String(format: "%.1f %%", result.waterPct))
            metricRow("Muscle", value: String(format: "%.1f %%", result.musclePct))
            metricRow("Bone", value: String(format: "%.2f kg", result.boneKg))
            if model.saved {
                Label("Saved to history", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.footnote)
            }
        }
    }

    private func metricRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var client: SBF70Client {
        // Safe: this view is only rendered while the session is ready.
        session.client!
    }
}
