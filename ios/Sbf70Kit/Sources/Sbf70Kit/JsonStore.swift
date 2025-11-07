import Foundation

/// Local JSON persistence under `Documents/Sbf70/`.
///
/// Files:
/// - `settings.json` — last peripheral, active uid, sync preferences
/// - `users.json` — cached user list from the scale
/// - `measurements-<uidHex>.json` — per-user measurements (CLI-compatible keys)
public actor JsonStore {
    public static let shared = JsonStore()

    public struct Settings: Codable, Equatable, Sendable {
        public var lastPeripheralUUID: String?
        public var lastDeviceName: String?
        public var activeUidHex: String?
        public var deleteAfterSync: Bool
        public var discardNoImpedance: Bool

        public init(
            lastPeripheralUUID: String? = nil,
            lastDeviceName: String? = nil,
            activeUidHex: String? = nil,
            deleteAfterSync: Bool = false,
            discardNoImpedance: Bool = false
        ) {
            self.lastPeripheralUUID = lastPeripheralUUID
            self.lastDeviceName = lastDeviceName
            self.activeUidHex = activeUidHex
            self.deleteAfterSync = deleteAfterSync
            self.discardNoImpedance = discardNoImpedance
        }
    }

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.directory = documents.appendingPathComponent("Sbf70", isDirectory: true)
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    // MARK: - Paths

    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    private var usersURL: URL { directory.appendingPathComponent("users.json") }

    private func measurementsURL(uidHex: String) -> URL {
        directory.appendingPathComponent("measurements-\(uidHex).json")
    }

    // MARK: - Generic IO

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectory()
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Settings

    public func loadSettings() throws -> Settings {
        try load(Settings.self, from: settingsURL) ?? Settings()
    }

    public func saveSettings(_ settings: Settings) throws {
        try save(settings, to: settingsURL)
    }

    // MARK: - Users

    public func loadUsers() throws -> [ScaleUser] {
        try load([ScaleUser].self, from: usersURL) ?? []
    }

    public func saveUsers(_ users: [ScaleUser]) throws {
        try save(users, to: usersURL)
    }

    // MARK: - Measurements

    public func loadMeasurements(uidHex: String) throws -> [ScaleMeasurement] {
        try load([ScaleMeasurement].self, from: measurementsURL(uidHex: uidHex)) ?? []
    }

    public func saveMeasurements(uidHex: String, _ measurements: [ScaleMeasurement]) throws {
        try save(measurements.sorted { $0.timestamp < $1.timestamp }, to: measurementsURL(uidHex: uidHex))
    }

    /// Merge new measurements into the store, keyed by timestamp (dedupe).
    @discardableResult
    public func mergeMeasurements(
        uidHex: String,
        new incoming: [ScaleMeasurement]
    ) throws -> (inserted: Int, updated: Int) {
        var existing = try loadMeasurements(uidHex: uidHex)
        var byTimestamp = Dictionary(uniqueKeysWithValues: existing.map { ($0.timestamp, $0) })
        var inserted = 0
        var updated = 0
        for measurement in incoming {
            if byTimestamp[measurement.timestamp] != nil {
                updated += 1
            } else {
                inserted += 1
            }
            byTimestamp[measurement.timestamp] = measurement
        }
        existing = Array(byTimestamp.values).sorted { $0.timestamp < $1.timestamp }
        try saveMeasurements(uidHex: uidHex, existing)
        return (inserted, updated)
    }

    public func deleteMeasurement(uidHex: String, timestamp: Int) throws {
        var existing = try loadMeasurements(uidHex: uidHex)
        existing.removeAll { $0.timestamp == timestamp }
        try saveMeasurements(uidHex: uidHex, existing)
    }

    public func measurementCount(uidHex: String) throws -> Int {
        try loadMeasurements(uidHex: uidHex).count
    }

    public func allMeasurementCounts() throws -> [String: Int] {
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var counts: [String: Int] = [:]
        for file in files where file.hasPrefix("measurements-") && file.hasSuffix(".json") {
            let uidHex = String(file.dropFirst("measurements-".count).dropLast(".json".count))
            counts[uidHex] = try loadMeasurements(uidHex: uidHex).count
        }
        return counts
    }

    // MARK: - CLI import (sbf70.py history JSON output)

    private struct CLIExport: Decodable {
        var users: [ScaleUser]?
        var measurements: [ScaleMeasurement]?
    }

    /// Import a `sbf70.py history` JSON export. Returns merged counts per uid.
    @discardableResult
    public func importCLIExport(_ data: Data) throws -> [String: (inserted: Int, updated: Int)] {
        let export = try decoder.decode(CLIExport.self, from: data)

        var results: [String: (inserted: Int, updated: Int)] = [:]
        let measurements = export.measurements ?? []
        let grouped = Dictionary(grouping: measurements, by: { $0.uid ?? "" })
        for (uidHex, items) in grouped {
            guard !uidHex.isEmpty else { continue }
            let result = try mergeMeasurements(uidHex: uidHex, new: items)
            results[uidHex] = result
        }

        if let users = export.users, !users.isEmpty {
            let existing = try loadUsers()
            var byUID = Dictionary(uniqueKeysWithValues: existing.map { ($0.uidHex, $0) })
            for user in users {
                byUID[user.uidHex] = user
            }
            try saveUsers(Array(byUID.values))
        }
        return results
    }

    // MARK: - Maintenance

    public func wipeAllData() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }
}
