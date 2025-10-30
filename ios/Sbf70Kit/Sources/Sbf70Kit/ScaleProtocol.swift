import Foundation

// MARK: - GATT

public enum ScaleGATT {
    public static let serviceUUID = "0000ffe0-0000-1000-8000-00805f9b34fb"
    public static let characteristicUUID = "0000ffe1-0000-1000-8000-00805f9b34fb"
}

// MARK: - Frame start bytes (SBF70 / BF710 family uses high nibble 0xE)

public enum ScaleStart {
    public static let cmd: UInt8 = 0xE7
    public static let initSession: UInt8 = 0xE6
    public static let setTime: UInt8 = 0xE9
    public static let disconnect: UInt8 = 0xEA
}

// MARK: - Command opcodes

public enum ScaleCmd {
    public static let userAdd: UInt8 = 0x31
    public static let userDelete: UInt8 = 0x32
    public static let userList: UInt8 = 0x33
    public static let userInfo: UInt8 = 0x34
    public static let userUpdate: UInt8 = 0x35
    public static let userDetails: UInt8 = 0x36
    public static let doMeasurement: UInt8 = 0x40
    public static let getSavedMeasurements: UInt8 = 0x41
    public static let savedMeasurement: UInt8 = 0x42
    public static let deleteSavedMeasurements: UInt8 = 0x43
    public static let getUnknownMeasurements: UInt8 = 0x46
    public static let unknownMeasurementInfo: UInt8 = 0x47
    public static let deleteUnknownMeasurement: UInt8 = 0x49
    public static let assignUnknownMeasurement: UInt8 = 0x4B
    public static let unknownMeasurement: UInt8 = 0x4C
    public static let setUnit: UInt8 = 0x4D
    public static let scaleStatus: UInt8 = 0x4F
    public static let weightMeasurement: UInt8 = 0x58
    public static let measurement: UInt8 = 0x59
    public static let scaleAck: UInt8 = 0xF0
    public static let appAck: UInt8 = 0xF1

    /// Frames that must be acknowledged (E7 F1 echo) while streaming.
    public static let streamingACK: Set<UInt8> = [
        userInfo, savedMeasurement, weightMeasurement,
        measurement, unknownMeasurementInfo, unknownMeasurement,
    ]
}

// MARK: - Device name hints (mirrors NAME_HINTS in sbf70.py)

public enum ScaleNames {
    public static let hints: [String] = [
        "sanitas sbf70",
        "sbf75",
        "aicdscale1",
        "beurer bf710",
        "bf700",
        "beurer bf700",
        "bf-700",
        "bf-800",
        "beurer bf800",
        "rt-libra",
        "libra-b",
        "libra-w",
    ]

    public static func matches(_ name: String?) -> Bool {
        guard let name else { return false }
        let lower = name.lowercased()
        return hints.contains { lower.contains($0) }
    }
}

public enum ScaleUnit {
    public static let names: [UInt8: String] = [1: "kg", 2: "lb", 4: "st"]

    public static func name(for code: UInt8) -> String {
        names[code] ?? String(code)
    }
}

// MARK: - Codec

public enum ScaleCodec {
    public static func u16BE(_ b: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(b[offset]) << 8) | UInt16(b[offset + 1])
    }

    public static func u32BE(_ b: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(b[offset]) << 24) | (UInt32(b[offset + 1]) << 16)
            | (UInt32(b[offset + 2]) << 8) | UInt32(b[offset + 3])
    }

    public static func encodeUID(_ uid: UInt64) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: uid >> 56), UInt8(truncatingIfNeeded: uid >> 48),
            UInt8(truncatingIfNeeded: uid >> 40), UInt8(truncatingIfNeeded: uid >> 32),
            UInt8(truncatingIfNeeded: uid >> 24), UInt8(truncatingIfNeeded: uid >> 16),
            UInt8(truncatingIfNeeded: uid >> 8), UInt8(truncatingIfNeeded: uid),
        ]
    }

    public static func decodeUID(_ b: [UInt8], _ offset: Int = 0) -> UInt64 {
        var uid: UInt64 = 0
        for i in 0..<8 {
            uid = (uid << 8) | UInt64(b[offset + i])
        }
        return uid
    }

    /// Weight unit is 50 g.
    public static func kgFromRaw(_ b: [UInt8], _ offset: Int) -> Double {
        Double(u16BE(b, offset)) * 50.0 / 1000.0
    }

    /// Percentage unit is 0.1 %.
    public static func percentFromRaw(_ b: [UInt8], _ offset: Int) -> Double {
        Double(u16BE(b, offset)) / 10.0
    }

    public static func decodeCString(_ b: [UInt8], _ offset: Int, maxLength: Int) -> String {
        let end = min(offset + maxLength, b.count)
        var chunk: [UInt8] = []
        for i in offset..<end {
            if b[i] == 0 { break }
            chunk.append(b[i])
        }
        return String(decoding: chunk, as: UTF8.self)
    }

    public static func hex(_ b: [UInt8]) -> String {
        b.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    public static func uidHex(_ uid: UInt64) -> String {
        String(format: "%016llX", uid)
    }

    public static func parseUID(_ text: String) -> UInt64? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "0x", with: "")
        return UInt64(cleaned, radix: 16)
    }

    /// Format a unix timestamp the way Python's datetime.isoformat() does (UTC, +00:00).
    public static func timeISO(unixSeconds: UInt32) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }
}

// MARK: - Errors

public enum SBF70Error: Error, LocalizedError, Equatable {
    case timeout
    case disconnected
    case rejected(status: UInt8, command: UInt8)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Timed out waiting for the scale. Wake it (step on it) and retry."
        case .disconnected:
            return "The scale disconnected."
        case let .rejected(status, command):
            return "Scale rejected command \(String(format: "%02X", command)) (status \(status)). "
                + "Is the user registered on the scale?"
        case let .malformed(message):
            return "Malformed frame: \(message)"
        }
    }
}
