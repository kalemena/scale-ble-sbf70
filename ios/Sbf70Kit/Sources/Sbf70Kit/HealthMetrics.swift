import Foundation

/// Platform-agnostic health calculations shared by the app and Kit targets.
public enum HealthMetrics {
    public enum BMIStatus: Sendable, Equatable {
        case below
        case ok
        case above
    }

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

    /// Standard adult BMI ranges: below 18.5, 18.5–24.9, and 25+.
    public static func bmiStatus(_ bmi: Double) -> BMIStatus {
        if bmi < 18.5 { return .below }
        if bmi < 25 { return .ok }
        return .above
    }
}
