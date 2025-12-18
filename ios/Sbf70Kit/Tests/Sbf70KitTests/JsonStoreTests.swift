import XCTest
@testable import Sbf70Kit

final class JsonStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sbf70-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> JsonStore {
        JsonStore(directory: directory)
    }

    private func sampleMeasurement(ts: Int = 1672865776, weight: Double = 69.8) -> ScaleMeasurement {
        ScaleMeasurement(
            timestamp: ts,
            timeISO: "2023-01-04T20:56:16+00:00",
            weightKg: weight,
            impedance: 473,
            fatPct: 21.9,
            waterPct: 52.2,
            musclePct: 40.1,
            boneKg: 11.7,
            uid: "0000000000000065"
        )
    }

    func testSettingsRoundTrip() async throws {
        let store = makeStore()
        let settings = JsonStore.Settings(
            lastPeripheralUUID: "ABC-123",
            lastDeviceName: "SANITAS SBF70",
            activeUidHex: "0000000000000065",
            deleteAfterSync: true
        )
        try await store.saveSettings(settings)
        let loaded = try await store.loadSettings()
        XCTAssertEqual(loaded, settings)
    }

    func testGoalsRoundTrip() async throws {
        let store = makeStore()
        let uid = "0000000000000065"
        try await store.setWeightGoal(uidHex: uid, minKg: 67, maxKg: 69.5)

        let goals = try await store.goals(uidHex: uid)
        XCTAssertEqual(goals.weightMinKg, 67)
        XCTAssertEqual(goals.weightMaxKg, 69.5)
        XCTAssertEqual(goals.weightRange, 67...69.5)

        try await store.setWeightGoal(uidHex: uid, minKg: 68, maxKg: 70)
        let allGoals = try await store.loadGoals()
        XCTAssertEqual(allGoals[uid]?.weightRange, 68...70)
    }

    func testLegacySingleWeightGoalDecodesAsRange() throws {
        let json = #"{"0000000000000065":{"weightKg":68.5}}"#
        let goals = try JSONDecoder().decode([String: JsonStore.UserGoals].self, from: Data(json.utf8))
        XCTAssertEqual(goals["0000000000000065"]?.weightRange, 68.5...68.5)
    }

    func testMergeDedupesByTimestamp() async throws {
        let store = makeStore()
        let uid = "0000000000000065"

        let first = try await store.mergeMeasurements(uidHex: uid, new: [
            sampleMeasurement(ts: 100),
            sampleMeasurement(ts: 200),
        ])
        XCTAssertEqual(first.inserted, 2)
        XCTAssertEqual(first.updated, 0)

        // Re-sync same ts=100 (updated weight) + new ts=300
        let second = try await store.mergeMeasurements(uidHex: uid, new: [
            sampleMeasurement(ts: 100, weight: 70.1),
            sampleMeasurement(ts: 300),
        ])
        XCTAssertEqual(second.inserted, 1)
        XCTAssertEqual(second.updated, 1)

        let all = try await store.loadMeasurements(uidHex: uid)
        XCTAssertEqual(all.map(\.timestamp), [100, 200, 300])
        XCTAssertEqual(all[0].weightKg, 70.1, accuracy: 0.001)
    }

    func testDeleteMeasurement() async throws {
        let store = makeStore()
        let uid = "0000000000000065"
        _ = try await store.mergeMeasurements(uidHex: uid, new: [
            sampleMeasurement(ts: 100),
            sampleMeasurement(ts: 200),
        ])
        try await store.deleteMeasurement(uidHex: uid, timestamp: 100)
        let all = try await store.loadMeasurements(uidHex: uid)
        XCTAssertEqual(all.map(\.timestamp), [200])
    }

    func testImportCLIExportFixture() async throws {
        // Minimal export in the exact shape of `sbf70.py history` output.
        let json = """
        {
          "address": "0BF867A1-5A6E-A05B-B8FB-8A46F7BF0000",
          "name": "SANITAS SBF70",
          "users": [
            { "uid": "0000000000000065", "name": "CLE", "year": 2000 }
          ],
          "measurements": [
            {
              "timestamp": 1672865776,
              "time_iso": "2023-01-04T20:56:16+00:00",
              "weight_kg": 69.8,
              "impedance": 473,
              "fat_pct": 21.9,
              "water_pct": 52.2,
              "muscle_pct": 40.1,
              "bone_kg": 11.7,
              "uid": "0000000000000065",
              "user_name": "CLE"
            },
            {
              "timestamp": 1691755645,
              "time_iso": "2023-08-11T12:07:25+00:00",
              "weight_kg": 68.7,
              "impedance": 449,
              "fat_pct": 21.0,
              "water_pct": 52.8,
              "muscle_pct": 40.4,
              "bone_kg": 11.5,
              "uid": "0000000000000065",
              "user_name": "CLE"
            }
          ]
        }
        """
        let store = makeStore()
        let results = try await store.importCLIExport(Data(json.utf8))
        XCTAssertEqual(results["0000000000000065"]?.inserted, 2)

        let measurements = try await store.loadMeasurements(uidHex: "0000000000000065")
        XCTAssertEqual(measurements.count, 2)
        XCTAssertEqual(measurements[0].weightKg, 69.8, accuracy: 0.001)

        let users = try await store.loadUsers()
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users[0].name, "CLE")
        XCTAssertEqual(users[0].year, 2000)
    }

    /// The app's own JSON export writes only uid/name/year per user — it must
    /// decode back without the scale-only `index`/`count` keys.
    func testScaleUserDecodesMinimalExportRoundTrip() throws {
        let json = #"{"uid":"0000000000000065","name":"CLE","year":2000}"#
        let user = try JSONDecoder().decode(ScaleUser.self, from: Data(json.utf8))
        XCTAssertEqual(user.uidHex, "0000000000000065")
        XCTAssertEqual(user.name, "CLE")
        XCTAssertEqual(user.year, 2000)
        XCTAssertEqual(user.index, 0)
        XCTAssertEqual(user.count, 0)

        let data = try JSONEncoder().encode(user)
        let decoded = try JSONDecoder().decode(ScaleUser.self, from: data)
        XCTAssertEqual(decoded, user)
    }

    func testImportCSVFixture() async throws {
        let csv = """
        timestamp,time_iso,weight_kg,impedance,fat_pct,water_pct,muscle_pct,bone_kg,uid,user_name
        1672865776,2023-01-04T20:56:16+00:00,69.8,473,21.9,52.2,40.1,11.7,0000000000000065,"CLE, home"
        1691755645,2023-08-11T12:07:25+00:00,68.7,449,21.0,52.8,40.4,11.5,0000000000000065,CLE
        """
        let store = makeStore()
        let results = try await store.importCSV(Data(csv.utf8))
        XCTAssertEqual(results["0000000000000065"]?.inserted, 2)

        let measurements = try await store.loadMeasurements(uidHex: "0000000000000065")
        XCTAssertEqual(measurements.count, 2)
        XCTAssertEqual(measurements[0].weightKg, 69.8, accuracy: 0.001)
        XCTAssertEqual(measurements[0].userName, "CLE, home")
    }

    func testWipeAllData() async throws {
        let store = makeStore()
        _ = try await store.mergeMeasurements(uidHex: "0000000000000065", new: [sampleMeasurement()])
        try await store.wipeAllData()
        let all = try await store.loadMeasurements(uidHex: "0000000000000065")
        XCTAssertTrue(all.isEmpty)
    }
}
