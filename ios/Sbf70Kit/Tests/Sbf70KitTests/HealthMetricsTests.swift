import XCTest
@testable import Sbf70Kit

final class HealthMetricsTests: XCTestCase {
    func testBMI() throws {
        let value = try XCTUnwrap(HealthMetrics.bmi(weightKg: 70, heightCm: 175))
        XCTAssertEqual(value, 22.857_142_857, accuracy: 0.000_001)
    }

    func testBMIRejectsInvalidInput() {
        XCTAssertNil(HealthMetrics.bmi(weightKg: 0, heightCm: 175))
        XCTAssertNil(HealthMetrics.bmi(weightKg: 70, heightCm: 0))
        XCTAssertNil(HealthMetrics.bmi(weightKg: -70, heightCm: 175))
        XCTAssertNil(HealthMetrics.bmi(weightKg: .nan, heightCm: 175))
        XCTAssertNil(HealthMetrics.bmi(weightKg: 70, heightCm: .infinity))
    }

    func testBMIStatusThresholds() {
        XCTAssertEqual(HealthMetrics.bmiStatus(18.4), .below)
        XCTAssertEqual(HealthMetrics.bmiStatus(18.5), .ok)
        XCTAssertEqual(HealthMetrics.bmiStatus(24.9), .ok)
        XCTAssertEqual(HealthMetrics.bmiStatus(25), .above)
    }
}
