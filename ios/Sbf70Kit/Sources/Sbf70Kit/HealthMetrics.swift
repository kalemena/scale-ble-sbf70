import Foundation

/// Platform-agnostic health calculations shared by the app and Kit targets.
public enum HealthMetrics {
    /// Body mass index (`weightKg / heightM²`).
    ///
    /// Returns `nil` when either input is non-positive or non-finite.
    public static func bmi(weightKg: Double, heightCm: Double) -> Double? {
        guard weightKg.isFinite, heightCm.isFinite, weightKg > 0, heightCm > 0 else {
            return nil
        }
        let heightM = heightCm / 100
        return weightKg / (heightM * heightM)
    }
}
