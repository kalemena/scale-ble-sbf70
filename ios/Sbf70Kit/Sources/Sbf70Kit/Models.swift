import Foundation

// MARK: - Scale status (parsed from E7 F0 4F ... — sbf70.py:326-345)

public struct ScaleStatus: Codable, Equatable, Sendable {
    public var battery: Int
    public var weightThresholdKg: Double
    public var fatThreshold: Double
    public var unit: String
    public var userExists: Bool
    public var userRefWeightExists: Bool
    public var userMeasurementExists: Bool
    public var version: Int

    public init(
        battery: Int,
        weightThresholdKg: Double,
        fatThreshold: Double,
        unit: String,
        userExists: Bool,
        userRefWeightExists: Bool,
        userMeasurementExists: Bool,
        version: Int
    ) {
        self.battery = battery
        self.weightThresholdKg = weightThresholdKg
        self.fatThreshold = fatThreshold
        self.unit = unit
        self.userExists = userExists
        self.userRefWeightExists = userRefWeightExists
        self.userMeasurementExists = userMeasurementExists
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case battery
        case weightThresholdKg = "weight_threshold_kg"
        case fatThreshold = "fat_threshold"
        case unit
        case userExists = "user_exists"
        case userRefWeightExists = "user_ref_weight_exists"
        case userMeasurementExists = "user_measurement_exists"
        case version
    }
}

// MARK: - Remote user stored on the scale (sbf70.py:161-172)

public struct ScaleUser: Codable, Identifiable, Hashable, Sendable {
    /// 16-digit hex uid; `id` for Identifiable.
    public var uidHex: String
    public var name: String
    public var year: Int
    public var index: Int
    public var count: Int
    public var birthday: String?
    public var heightCm: Int?
    public var sex: String?
    public var activity: Int?

    public var id: String { uidHex }

    /// e.g. "CLE (000065)" — 3-letter nickname + last 6 hex digits of the uid.
    /// Shared display for users and measurements referencing them.
    public var displayName: String {
        let code = String(uidHex.suffix(6)).uppercased()
        let nick = name.trimmingCharacters(in: .whitespaces).uppercased()
        return nick.isEmpty ? code : "\(nick) (\(code))"
    }

    public var uid: UInt64 {
        UInt64(uidHex, radix: 16) ?? 0
    }

    public init(
        uidHex: String,
        name: String,
        year: Int,
        index: Int = 0,
        count: Int = 0,
        birthday: String? = nil,
        heightCm: Int? = nil,
        sex: String? = nil,
        activity: Int? = nil
    ) {
        self.uidHex = uidHex
        self.name = name
        self.year = year
        self.index = index
        self.count = count
        self.birthday = birthday
        self.heightCm = heightCm
        self.sex = sex
        self.activity = activity
    }

    public init(uid: UInt64, name: String, year: Int) {
        self.init(uidHex: ScaleCodec.uidHex(uid), name: name, year: year)
    }

    enum CodingKeys: String, CodingKey {
        case uidHex = "uid"
        case name, year, index, count, birthday
        case heightCm = "height_cm"
        case sex, activity
    }
}

// MARK: - Measurement (16-byte payload — sbf70.py:175-202)

public struct ScaleMeasurement: Codable, Identifiable, Equatable, Sendable {
    public var timestamp: Int
    public var timeISO: String
    public var weightKg: Double
    public var impedance: Int
    public var fatPct: Double
    public var waterPct: Double
    public var musclePct: Double
    public var boneKg: Double
    public var uid: String?
    public var userName: String?

    public var id: String { "\(timestamp)-\(weightKg)" }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    public init(
        timestamp: Int,
        timeISO: String,
        weightKg: Double,
        impedance: Int,
        fatPct: Double,
        waterPct: Double,
        musclePct: Double,
        boneKg: Double,
        uid: String? = nil,
        userName: String? = nil
    ) {
        self.timestamp = timestamp
        self.timeISO = timeISO
        self.weightKg = weightKg
        self.impedance = impedance
        self.fatPct = fatPct
        self.waterPct = waterPct
        self.musclePct = musclePct
        self.boneKg = boneKg
        self.uid = uid
        self.userName = userName
    }

    /// Parse the 16-byte big-endian payload (sbf70.py:187-202).
    public init(payload: [UInt8], uid: UInt64? = nil) throws {
        guard payload.count >= 16 else {
            throw SBF70Error.malformed("measurement payload too short: \(payload.count) bytes")
        }
        let ts = ScaleCodec.u32BE(payload, 0)
        self.init(
            timestamp: Int(ts),
            timeISO: ScaleCodec.timeISO(unixSeconds: ts),
            weightKg: (ScaleCodec.kgFromRaw(payload, 4) * 100).rounded() / 100,
            impedance: Int(ScaleCodec.u16BE(payload, 6)),
            fatPct: (ScaleCodec.percentFromRaw(payload, 8) * 10).rounded() / 10,
            waterPct: (ScaleCodec.percentFromRaw(payload, 10) * 10).rounded() / 10,
            musclePct: (ScaleCodec.percentFromRaw(payload, 12) * 10).rounded() / 10,
            boneKg: (ScaleCodec.kgFromRaw(payload, 14) * 100).rounded() / 100,
            uid: uid.map { ScaleCodec.uidHex($0) }
        )
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case timeISO = "time_iso"
        case weightKg = "weight_kg"
        case impedance
        case fatPct = "fat_pct"
        case waterPct = "water_pct"
        case musclePct = "muscle_pct"
        case boneKg = "bone_kg"
        case uid
        case userName = "user_name"
    }
}
