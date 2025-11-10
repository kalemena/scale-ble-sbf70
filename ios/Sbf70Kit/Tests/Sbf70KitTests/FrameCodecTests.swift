import XCTest
@testable import Sbf70Kit

final class FrameCodecTests: XCTestCase {
    func testU16BE() {
        XCTAssertEqual(ScaleCodec.u16BE([0x01, 0x02], 0), 0x0102)
        XCTAssertEqual(ScaleCodec.u16BE([0xFF, 0xFF], 0), 65535)
        XCTAssertEqual(ScaleCodec.u16BE([0x00, 0x00, 0x12, 0x34], 2), 0x1234)
    }

    func testU32BE() {
        XCTAssertEqual(ScaleCodec.u32BE([0x00, 0x00, 0x00, 0x01], 0), 1)
        XCTAssertEqual(ScaleCodec.u32BE([0x65, 0x00, 0x00, 0x01], 0), 0x65000001)
    }

    func testUIDRoundTrip() {
        let uid: UInt64 = 0x0000_0000_0000_0065
        let encoded = ScaleCodec.encodeUID(uid)
        XCTAssertEqual(encoded.count, 8)
        XCTAssertEqual(encoded, [0, 0, 0, 0, 0, 0, 0, 0x65])
        XCTAssertEqual(ScaleCodec.decodeUID(encoded, 0), uid)
    }

    func testUIDHexAndParse() {
        let uid: UInt64 = 0x0000_0000_0000_0065
        XCTAssertEqual(ScaleCodec.uidHex(uid), "0000000000000065")
        XCTAssertEqual(ScaleCodec.parseUID("0000000000000065"), uid)
        XCTAssertEqual(ScaleCodec.parseUID("00:00:00:00:00:00:00:65"), uid)
        XCTAssertEqual(ScaleCodec.parseUID("0x65"), uid)
    }

    func testKgFromRaw() {
        // 50 g units: 1400 -> 70.0 kg
        XCTAssertEqual(ScaleCodec.kgFromRaw([0x05, 0x78], 0), 70.0, accuracy: 0.001)
    }

    func testPercentFromRaw() {
        // 0.1 % units: 215 -> 21.5 %
        XCTAssertEqual(ScaleCodec.percentFromRaw([0x00, 0xD7], 0), 21.5, accuracy: 0.001)
    }

    func testDecodeCString() {
        let frame: [UInt8] = Array("CLE".utf8) + [0, 0]
        XCTAssertEqual(ScaleCodec.decodeCString(frame, 0, maxLength: 3), "CLE")
        XCTAssertEqual(ScaleCodec.decodeCString([0x41, 0x00, 0x42], 0, maxLength: 3), "A")
    }

    func testNameMatches() {
        XCTAssertTrue(ScaleNames.matches("SANITAS SBF70"))
        XCTAssertTrue(ScaleNames.matches("Beurer BF710"))
        XCTAssertTrue(ScaleNames.matches("SBF75"))
        XCTAssertFalse(ScaleNames.matches("Mi Band"))
        XCTAssertFalse(ScaleNames.matches(nil))
    }

    func testMeasurementPayloadParse() throws {
        // ts=0x65000001, weight=1400 (70.00 kg), Z=500,
        // fat=215 (21.5%), water=522 (52.2%), muscle=401 (40.1%), bone=234 (11.7 kg)
        var payload: [UInt8] = [0x65, 0x00, 0x00, 0x01]
        payload += [0x05, 0x78] // weight
        payload += [0x01, 0xF4] // impedance 500
        payload += [0x00, 0xD7] // fat 21.5
        payload += [0x02, 0x0A] // water 52.2
        payload += [0x01, 0x91] // muscle 40.1
        payload += [0x00, 0xEA] // bone 11.7
        XCTAssertEqual(payload.count, 16)

        let measurement = try ScaleMeasurement(payload: payload, uid: 0x65)
        XCTAssertEqual(measurement.timestamp, 0x65000001)
        XCTAssertEqual(measurement.weightKg, 70.0, accuracy: 0.001)
        XCTAssertEqual(measurement.impedance, 500)
        XCTAssertEqual(measurement.fatPct, 21.5, accuracy: 0.001)
        XCTAssertEqual(measurement.waterPct, 52.2, accuracy: 0.001)
        XCTAssertEqual(measurement.musclePct, 40.1, accuracy: 0.001)
        XCTAssertEqual(measurement.boneKg, 11.7, accuracy: 0.001)
        XCTAssertEqual(measurement.uid, "0000000000000065")
        XCTAssertTrue(measurement.timeISO.hasSuffix("+00:00"))
    }

    func testMeasurementPayloadTooShort() {
        XCTAssertThrowsError(try ScaleMeasurement(payload: [0x00, 0x01]))
    }

    func testMeasurementJSONMatchesCLIKeys() throws {
        var payload: [UInt8] = [0x65, 0x00, 0x00, 0x01]
        payload += [0x05, 0x78, 0x01, 0xF4, 0x00, 0xD7, 0x02, 0x0A, 0x01, 0x91, 0x00, 0xEA]
        let measurement = try ScaleMeasurement(payload: payload, uid: 0x65)

        let data = try JSONEncoder().encode(measurement)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["timestamp", "time_iso", "weight_kg", "impedance", "fat_pct",
                    "water_pct", "muscle_pct", "bone_kg", "uid"]
        {
            XCTAssertNotNil(json[key], "missing key \(key)")
        }
    }
}
