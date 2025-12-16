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
    @State private var showBonePct = false
    @State private var detailMeasurement: ScaleMeasurement?
    @State private var usersByUID: [String: ScaleUser] = [:]
    @State private var showSync = false
    @State private var chartFullScreen = false
    @State private var readingsExpanded = false
    @State private var rangeStart: Double = 0
    @State private var rangeEnd: Double = 1

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
        .onChange(of: session.state) { _, state in
            if case .ready = state {
                Task { await reload() }
            }
        }
        .sheet(item: Binding(
            get: { chartFullScreen ? nil : detailMeasurement },
            set: { detailMeasurement = $0 }
        )) { measurement in
            MeasurementDetailSheet(
                measurement: measurement,
                userName: measurementUserName(measurement),
                bmi: bmi(for: measurement)
            )
        }
        .sheet(isPresented: $showSync) {
            SyncView()
        }
        .fullScreenCover(isPresented: $chartFullScreen) {
            fullScreenChart
        }
    }

    private var fullScreenChart: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                chart
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                legend
                    .font(.title3)
            }
            .padding()

            Button {
                chartFullScreen = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .accessibilityLabel("Close")
        }
        .sheet(item: $detailMeasurement) { measurement in
            MeasurementDetailSheet(
                measurement: measurement,
                userName: measurementUserName(measurement),
                bmi: bmi(for: measurement)
            )
        }
    }

    private var legend: some View {
        HStack(spacing: 20) {
            toggleChip("scalemass.fill", label: "Weight", isOn: .constant(true), color: .blue)
            toggleChip("pizza.slice", label: "Fat %", isOn: $showFat, color: .orange)
            toggleChip("humidity.fill", label: "Water %", isOn: $showWater, color: .cyan)
            toggleChip("dumbbell.fill", label: "Muscle %", isOn: $showMuscle, color: .green)
            toggleChip("figure.walk", label: "Bone %", isOn: $showBonePct, color: .pink)
        }
        .frame(maxWidth: .infinity)
    }

    private var timeSelector: some View {
        VStack(spacing: 4) {
            RangeSlider(lowerValue: $rangeStart, upperValue: $rangeEnd)
            HStack {
                Text(rangeLabel(at: rangeStart))
                Spacer()
                Text(rangeLabel(at: rangeEnd))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Time range")
    }

    /// Full date span covered by the stored readings.
    private var dateBounds: (start: Date, end: Date)? {
        let dates = measurements.map(\.date)
        guard let start = dates.min(), let end = dates.max() else { return nil }
        return (start, end)
    }

    /// Readings inside the selected time range.
    private var visibleMeasurements: [ScaleMeasurement] {
        guard let bounds = dateBounds, bounds.end > bounds.start else { return measurements }
        let span = bounds.end.timeIntervalSince(bounds.start)
        let start = bounds.start.addingTimeInterval(span * rangeStart)
        let end = bounds.start.addingTimeInterval(span * rangeEnd)
        return measurements.filter { $0.date >= start && $0.date <= end }
    }

    private func rangeLabel(at fraction: Double) -> String {
        guard let bounds = dateBounds else { return "" }
        let span = bounds.end.timeIntervalSince(bounds.start)
        let date = bounds.start.addingTimeInterval(span * fraction)
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var chartAndList: some View {
        List {
            Section {
                chart
                    .frame(height: 220)
                    .contentShape(Rectangle())
                    .onLongPressGesture {
                        chartFullScreen = true
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))

                legend
                    .font(.caption)

                timeSelector
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
            }

            Section {
                if readingsExpanded {
                    ForEach(visibleMeasurements.reversed()) { measurement in
                        row(measurement)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                detailMeasurement = measurement
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    delete(measurement)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                Button {
                    withAnimation {
                        readingsExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text("\(visibleMeasurements.count) readings")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(readingsExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .accessibilityLabel("\(visibleMeasurements.count) readings")
                .accessibilityValue(readingsExpanded ? "Expanded" : "Collapsed")
            }
        }
    }

    private var chart: some View {
        let weightDomain = weightRange
        let percentDomain = 0.0...100.0
        let percentTickPositions = [0.0, 20.0, 40.0, 60.0, 80.0, 100.0].map {
            chartY(forPercent: $0, weightRange: weightDomain, percentRange: percentDomain)
        }

        return Chart(visibleMeasurements) { m in
            LineMark(x: .value("Date", m.date), y: .value("Weight", m.weightKg))
                .foregroundStyle(.blue)
                .interpolationMethod(.monotone)
            PointMark(x: .value("Date", m.date), y: .value("Weight", m.weightKg))
                .foregroundStyle(.blue)

            if showFat {
                LineMark(
                    x: .value("Date", m.date),
                    y: .value("Fat %", chartY(forPercent: m.fatPct, weightRange: weightDomain, percentRange: percentDomain)),
                    series: .value("Metric", "Fat %")
                )
                .foregroundStyle(.orange)
                .interpolationMethod(.monotone)
            }
            if showWater {
                LineMark(
                    x: .value("Date", m.date),
                    y: .value("Water %", chartY(forPercent: m.waterPct, weightRange: weightDomain, percentRange: percentDomain)),
                    series: .value("Metric", "Water %")
                )
                .foregroundStyle(.cyan)
                .interpolationMethod(.monotone)
            }
            if showMuscle {
                LineMark(
                    x: .value("Date", m.date),
                    y: .value("Muscle %", chartY(forPercent: m.musclePct, weightRange: weightDomain, percentRange: percentDomain)),
                    series: .value("Metric", "Muscle %")
                )
                .foregroundStyle(.green)
                .interpolationMethod(.monotone)
            }
            if showBonePct, let bonePct = bonePercent(for: m) {
                LineMark(
                    x: .value("Date", m.date),
                    y: .value("Bone %", chartY(forPercent: bonePct, weightRange: weightDomain, percentRange: percentDomain)),
                    series: .value("Metric", "Bone %")
                )
                .foregroundStyle(.pink)
                .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: weightDomain)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let kg = value.as(Double.self) {
                        Text(String(format: "%.1f kg", kg))
                    }
                }
            }
            AxisMarks(position: .trailing, values: percentTickPositions) { value in
                AxisTick()
                AxisValueLabel {
                    if let y = value.as(Double.self) {
                        let pct = percentValue(atY: y, weightRange: weightDomain, percentRange: percentDomain)
                        Text(String(format: "%.0f%%", pct))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let origin = geometry[plotFrame].origin
                        guard let date: Date = proxy.value(atX: location.x - origin.x) else { return }
                        if let nearest = nearestMeasurement(to: date) {
                            detailMeasurement = nearest
                        }
                    }
            }
        }
    }

    /// Closest reading to a date tapped on the chart.
    private func nearestMeasurement(to date: Date) -> ScaleMeasurement? {
        visibleMeasurements.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    private func bonePercent(for measurement: ScaleMeasurement) -> Double? {
        guard measurement.weightKg > 0 else { return nil }
        return measurement.boneKg / measurement.weightKg * 100
    }

    /// Weight axis domain with a little breathing room above and below.
    private var weightRange: ClosedRange<Double> {
        let weights = visibleMeasurements.map(\.weightKg)
        guard let minWeight = weights.min(), let maxWeight = weights.max() else { return 0...100 }
        let span = max(maxWeight - minWeight, 1.0)
        let mid = (minWeight + maxWeight) / 2
        let padding = span * 0.1
        return (mid - span / 2 - padding)...(mid + span / 2 + padding)
    }

    /// Map a percentage onto the chart's weight-based y scale.
    private func chartY(
        forPercent percent: Double,
        weightRange: ClosedRange<Double>,
        percentRange: ClosedRange<Double>
    ) -> Double {
        let percentSpan = percentRange.upperBound - percentRange.lowerBound
        guard percentSpan > 0 else { return weightRange.lowerBound }
        let fraction = (percent - percentRange.lowerBound) / percentSpan
        return weightRange.lowerBound + fraction * (weightRange.upperBound - weightRange.lowerBound)
    }

    /// Inverse of `chartY(forPercent:...)` for the trailing percentage axis.
    private func percentValue(
        atY y: Double,
        weightRange: ClosedRange<Double>,
        percentRange: ClosedRange<Double>
    ) -> Double {
        let weightSpan = weightRange.upperBound - weightRange.lowerBound
        guard weightSpan > 0 else { return percentRange.lowerBound }
        let fraction = (y - weightRange.lowerBound) / weightSpan
        return percentRange.lowerBound + fraction * (percentRange.upperBound - percentRange.lowerBound)
    }

    private func toggleChip(_ icon: String, label: String, isOn: Binding<Bool>, color: Color) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: icon)
                .frame(width: 32, height: 32)
                .foregroundStyle(isOn.wrappedValue ? color : .secondary)
                .opacity(isOn.wrappedValue ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func row(_ m: ScaleMeasurement) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(m.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                Spacer()
                if let trend = weightTrend(for: m), let weightDelta = weightDelta(for: m) {
                    HStack(spacing: 2) {
                        Text(String(format: "%+.2f", weightDelta))
                            .monospacedDigit()
                        Image(systemName: trend.icon)
                    }
                    .font(.caption)
                    .foregroundStyle(weightTrendColor(for: m, delta: weightDelta))
                    .accessibilityLabel("\(trend.accessibilityLabel) \(String(format: "%+.2f", weightDelta)) kg")
                }
                Text(String(format: "%.2f kg", m.weightKg))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }
            summaryBar(for: m)
                .font(.caption2)
        }
    }

    private enum TrendDirection {
        case up, down

        var icon: String {
            switch self {
            case .up: "arrow.up"
            case .down: "arrow.down"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .up: "Increased"
            case .down: "Decreased"
            }
        }
    }

    /// Reading immediately before `m` by date.
    private func previousMeasurement(for m: ScaleMeasurement) -> ScaleMeasurement? {
        guard let index = measurements.firstIndex(where: { $0.id == m.id }),
              index > 0
        else { return nil }
        return measurements[index - 1]
    }

    private func trend(current: Double?, previous: Double?) -> TrendDirection? {
        guard let current, let previous else { return nil }
        if current > previous { return .up }
        if current < previous { return .down }
        return nil
    }

    private func delta(current: Double?, previous: Double?) -> Double? {
        guard let current, let previous else { return nil }
        return current - previous
    }

    /// Compare weight against the previous reading by date.
    private func weightTrend(for m: ScaleMeasurement) -> TrendDirection? {
        trend(current: m.weightKg, previous: previousMeasurement(for: m)?.weightKg)
    }

    private func weightDelta(for m: ScaleMeasurement) -> Double? {
        delta(current: m.weightKg, previous: previousMeasurement(for: m)?.weightKg)
    }

    /// Target weight for the reading's user, if one has been set.
    private func weightGoal(for m: ScaleMeasurement) -> Double? {
        let uidHex = m.uid ?? appSettings.activeUidHex
        guard let uidHex else { return nil }
        return appSettings.goals[uidHex]?.weightKg
    }

    /// Green when the reading moved closer to the goal, red when it moved away,
    /// and neutral without a goal or when the distance is unchanged.
    private func weightTrendColor(for m: ScaleMeasurement, delta: Double) -> Color {
        guard let goal = weightGoal(for: m) else { return .secondary }
        let previousWeight = m.weightKg - delta
        let currentDistance = abs(m.weightKg - goal)
        let previousDistance = abs(previousWeight - goal)
        if currentDistance < previousDistance { return .green }
        if currentDistance > previousDistance { return .red }
        return .secondary
    }

    @ViewBuilder
    private func summaryBar(for m: ScaleMeasurement) -> some View {
        let bmiInfo = BMIInfo(bmi: bmi(for: m))
        let previous = previousMeasurement(for: m)
        let currentBmi = bmi(for: m)
        let previousBmi = previous.flatMap { bmi(for: $0) }
        HStack(alignment: .top, spacing: 12) {
            summaryItem(
                icon: bmiInfo.icon,
                value: bmiInfo.text,
                color: bmiInfo.color,
                label: "BMI",
                delta: delta(current: currentBmi, previous: previousBmi),
                decimals: 1
            )
            summaryItem(
                icon: "pizza.slice",
                value: String(format: "%.1f%%", m.fatPct),
                label: "Fat",
                delta: delta(current: m.fatPct, previous: previous?.fatPct),
                decimals: 1
            )
            summaryItem(
                icon: "humidity.fill",
                value: String(format: "%.1f%%", m.waterPct),
                label: "Water",
                delta: delta(current: m.waterPct, previous: previous?.waterPct),
                decimals: 1
            )
            summaryItem(
                icon: "dumbbell.fill",
                value: String(format: "%.1f%%", m.musclePct),
                label: "Muscle",
                delta: delta(current: m.musclePct, previous: previous?.musclePct),
                decimals: 1
            )
            summaryItem(
                icon: "figure.walk",
                value: String(format: "%.2f kg", m.boneKg),
                label: "Bone",
                delta: delta(current: m.boneKg, previous: previous?.boneKg),
                decimals: 2
            )
        }
        .foregroundStyle(.secondary)
    }

    private func summaryItem(
        icon: String,
        value: String,
        color: Color = .secondary,
        label: String,
        delta: Double?,
        decimals: Int
    ) -> some View {
        let trend: TrendDirection? = {
            guard let delta else { return nil }
            if delta > 0 { return .up }
            if delta < 0 { return .down }
            return nil
        }()
        return VStack(spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                Text(value)
                    .monospacedDigit()
            }
            if let trend, let delta {
                HStack(spacing: 2) {
                    Image(systemName: trend.icon)
                    Text(String(format: "%+.\(decimals)f", delta))
                        .monospacedDigit()
                }
                .font(.caption2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
        .accessibilityValue(trend.map { "\($0.accessibilityLabel) \(String(format: "%+.\(decimals)f", delta ?? 0))" } ?? "")
    }

    private func bmi(for m: ScaleMeasurement) -> Double? {
        let heightCm =
            m.uid.flatMap { usersByUID[$0]?.heightCm }
            ?? appSettings.activeUidHex.flatMap { usersByUID[$0]?.heightCm }
        guard let heightCm, heightCm > 0 else { return nil }
        return HealthMetrics.bmi(weightKg: m.weightKg, heightCm: Double(heightCm))
    }

    private func reload() async {
        // Load the cached users first so BMI is available on the first render.
        let users = (try? await JsonStore.shared.loadUsers()) ?? []
        usersByUID = Dictionary(uniqueKeysWithValues: users.map { ($0.uidHex, $0) })

        guard let uidHex = appSettings.activeUidHex else {
            measurements = []
            return
        }
        measurements = (try? await JsonStore.shared.loadMeasurements(uidHex: uidHex)) ?? []
    }

    /// Same "CLE (000065)" display as the Users tab.
    private func measurementUserName(_ m: ScaleMeasurement) -> String {
        if let uid = m.uid, let user = usersByUID[uid] {
            return user.displayName
        }
        let code = String((m.uid ?? m.userName ?? "").suffix(6)).uppercased()
        guard let name = m.userName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return code.isEmpty ? "Unknown user" : code
        }
        return "\(name.uppercased()) (\(code))"
    }

    private func delete(_ m: ScaleMeasurement) {
        guard let uidHex = appSettings.activeUidHex else { return }
        Task {
            try? await JsonStore.shared.deleteMeasurement(uidHex: uidHex, timestamp: m.timestamp)
            await reload()
        }
    }

}

/// Two-handle slider for picking a fraction-based range.
private struct RangeSlider: View {
    @Binding var lowerValue: Double
    @Binding var upperValue: Double

    private let handleDiameter: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let usableWidth = max(geometry.size.width - handleDiameter, 1)
            let lowerX = usableWidth * lowerValue
            let upperX = usableWidth * upperValue

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 4)
                    .padding(.horizontal, handleDiameter / 2)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(upperX - lowerX, 0), height: 4)
                    .offset(x: handleDiameter / 2 + lowerX)

                handle
                    .offset(x: lowerX)
                    .gesture(dragGesture(usableWidth: usableWidth, isLower: true))
                handle
                    .offset(x: upperX)
                    .gesture(dragGesture(usableWidth: usableWidth, isLower: false))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .coordinateSpace(.named("rangeSlider"))
        }
        .frame(height: handleDiameter)
    }

    private var handle: some View {
        Circle()
            .fill(Color(.systemBackground))
            .frame(width: handleDiameter, height: handleDiameter)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }

    private func dragGesture(usableWidth: CGFloat, isLower: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("rangeSlider"))
            .onChanged { value in
                let fraction = (value.location.x - handleDiameter / 2) / usableWidth
                let clamped = min(max(fraction, 0), 1)
                if isLower {
                    lowerValue = min(clamped, upperValue)
                } else {
                    upperValue = max(clamped, lowerValue)
                }
            }
    }
}

/// Long-press detail sheet: every field stored for one reading.
private struct MeasurementDetailSheet: View {
    let measurement: ScaleMeasurement
    let userName: String?
    let bmi: Double?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Date") {
                    LabeledContent("Local", value: measurement.date.formatted(date: .complete, time: .standard))
                }
                Section("Body") {
                    MetricRow(
                        label: "Weight",
                        icon: "scalemass.fill",
                        value: String(format: "%.2f kg", measurement.weightKg)
                    )
                    MetricRow(label: "BMI", icon: bmiInfo.icon, value: bmiInfo.text, iconColor: bmiInfo.color)
                    MetricRow(
                        label: "Fat",
                        icon: "pizza.slice",
                        value: String(format: "%.1f %%", measurement.fatPct)
                    )
                    MetricRow(
                        label: "Water",
                        icon: "humidity.fill",
                        value: String(format: "%.1f %%", measurement.waterPct)
                    )
                    MetricRow(
                        label: "Muscle",
                        icon: "dumbbell.fill",
                        value: String(format: "%.1f %%", measurement.musclePct)
                    )
                    MetricRow(
                        label: "Bone",
                        icon: "figure.walk",
                        value: String(format: "%.2f kg", measurement.boneKg)
                    )
                    MetricRow(
                        label: "Impedance",
                        icon: "bolt.fill",
                        value: "\(measurement.impedance) Ω"
                    )
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

    /// e.g. "CLE (000065)" — same display as the Users tab.
    private var userLabel: String {
        userName ?? "—"
    }

    private var bmiInfo: BMIInfo {
        BMIInfo(bmi: bmi)
    }
}
