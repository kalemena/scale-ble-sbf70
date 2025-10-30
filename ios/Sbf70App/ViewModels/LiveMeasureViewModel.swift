import Foundation
import Sbf70Kit

/// Runs a live measurement (`DO_MEASUREMENT` + weight/body-comp frames).
@MainActor
final class LiveMeasureViewModel: ObservableObject {
    @Published private(set) var isMeasuring = false
    @Published private(set) var liveWeightKg: Double?
    @Published private(set) var isStable = false
    @Published private(set) var result: ScaleMeasurement?
    @Published private(set) var saved = false
    @Published var errorMessage: String?

    func measure(client: SBF70Client, uidHex: String) async {
        isMeasuring = true
        liveWeightKg = nil
        isStable = false
        result = nil
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
}
