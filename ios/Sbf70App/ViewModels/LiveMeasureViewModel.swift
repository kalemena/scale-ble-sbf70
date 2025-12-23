import Foundation
import Sbf70Kit

/// Runs a live measurement (`DO_MEASUREMENT` + weight/body-comp frames).
@MainActor
final class LiveMeasureViewModel: ObservableObject {
    @Published private(set) var isMeasuring = false
    @Published private(set) var liveWeightKg: Double?
    @Published private(set) var isStable = false
    @Published private(set) var result: ScaleMeasurement?
    @Published private(set) var previous: ScaleMeasurement?
    @Published private(set) var saved = false
    @Published var errorMessage: String?

    func measure(client: SBF70Client, uidHex: String) async {
        isMeasuring = true
        liveWeightKg = nil
        isStable = false
        result = nil
        previous = nil
        saved = false
        errorMessage = nil
        defer { isMeasuring = false }

        let uid = UInt64(uidHex, radix: 16) ?? 0
        do {
            let (weights, measurement) = try await client.liveMeasure(uid: uid, hold: 30.0) { [weak self] kg, stable in
                Task { @MainActor in
                    self?.liveWeightKg = kg
                    self?.isStable = stable
                }
            }
            _ = weights
            if let measurement {
                result = measurement
                var toSave = measurement
                toSave.uid = uidHex
                previous = await Self.latestStoredMeasurement(before: toSave.timestamp, uidHex: uidHex)
                try await JsonStore.shared.mergeMeasurements(uidHex: uidHex, new: [toSave])
                saved = true
            } else {
                errorMessage = "Weight recorded, but body composition did not arrive. "
                    + "Stand still a few more seconds after the weight stabilises, then retry."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Most recent stored reading strictly before the new one, for trend deltas.
    private static func latestStoredMeasurement(before timestamp: Int, uidHex: String) async -> ScaleMeasurement? {
        let stored = (try? await JsonStore.shared.loadMeasurements(uidHex: uidHex)) ?? []
        return stored
            .filter { $0.timestamp < timestamp }
            .max { $0.timestamp < $1.timestamp }
    }
}
