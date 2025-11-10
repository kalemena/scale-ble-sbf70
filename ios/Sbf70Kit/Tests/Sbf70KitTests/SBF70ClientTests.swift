import XCTest
@testable import Sbf70Kit

final class SBF70ClientTests: XCTestCase {
    private func makePayload(
        ts: UInt32 = 0x6500_0001,
        weightRaw: UInt16 = 1400, // 70.00 kg
        impedance: UInt16 = 500,
        fatRaw: UInt16 = 215, // 21.5 %
        waterRaw: UInt16 = 522, // 52.2 %
        muscleRaw: UInt16 = 401, // 40.1 %
        boneRaw: UInt16 = 234 // 11.7 kg
    ) -> [UInt8] {
        var p: [UInt8] = [
            UInt8(truncatingIfNeeded: ts >> 24), UInt8(truncatingIfNeeded: ts >> 16),
            UInt8(truncatingIfNeeded: ts >> 8), UInt8(truncatingIfNeeded: ts),
            UInt8(truncatingIfNeeded: weightRaw >> 8), UInt8(truncatingIfNeeded: weightRaw),
            UInt8(truncatingIfNeeded: impedance >> 8), UInt8(truncatingIfNeeded: impedance),
            UInt8(truncatingIfNeeded: fatRaw >> 8), UInt8(truncatingIfNeeded: fatRaw),
            UInt8(truncatingIfNeeded: waterRaw >> 8), UInt8(truncatingIfNeeded: waterRaw),
            UInt8(truncatingIfNeeded: muscleRaw >> 8), UInt8(truncatingIfNeeded: muscleRaw),
            UInt8(truncatingIfNeeded: boneRaw >> 8), UInt8(truncatingIfNeeded: boneRaw),
        ]
        XCTAssertEqual(p.count, 16)
        return p
    }

    private func makeClient(_ transport: MockTransport) -> SBF70Client {
        let client = SBF70Client(transport: transport, timeout: 2.0)
        return client
    }

    // MARK: - initSession

    func testInitSessionSequence() async throws {
        let transport = MockTransport()
        transport.onWrite = { frame in
            if frame == [0xE6, 0x01] {
                transport.emitAsync([0xE6, 0x01])
            }
        }
        let client = makeClient(transport)
        await client.start()
        try await client.initSession()

        let written = transport.written
        XCTAssertEqual(written.first, [0xE6, 0x01], "INIT must be first write")
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(written[1].first, 0xE9, "SET_TIME follows INIT")
        XCTAssertEqual(written[1].count, 5, "E9 + 4-byte unix time")
    }

    // MARK: - getStatus

    func testGetStatusParsesFields() async throws {
        let transport = MockTransport()
        transport.onWrite = { frame in
            switch frame.first {
            case 0xE6:
                transport.emitAsync([0xE6, 0x01])
            case 0xE7 where frame.count >= 10 && frame[1] == 0x4F:
                // E7 F0 4F pad bat=92 thr_w=40 thr_f=220 unit=1 uexist uref umeas ver=5
                transport.emitAsync([0xE7, 0xF0, 0x4F, 0x00, 92, 40, 0xDC, 0x01, 0x00, 0x00, 0x00, 0x05])
            default:
                break
            }
        }
        let client = makeClient(transport)
        await client.start()
        try await client.initSession()
        let status = try await client.getStatus(uid: 0x65)

        XCTAssertEqual(status.battery, 92)
        XCTAssertEqual(status.weightThresholdKg, 4.0, accuracy: 0.001)
        XCTAssertEqual(status.fatThreshold, 22.0, accuracy: 0.001)
        XCTAssertEqual(status.unit, "kg")
        XCTAssertTrue(status.userExists)
        XCTAssertEqual(status.version, 5)
    }

    // MARK: - listUsers (auto-ACK)

    func testListUsersEmitsAppACK() async throws {
        let transport = MockTransport()
        var userInfoSent = false
        transport.onWrite = { frame in
            switch frame.first {
            case 0xE6:
                transport.emitAsync([0xE6, 0x01])
            case 0xE7 where frame[1] == 0x33:
                // ACK: E7 F0 33 pad count=1 max=8
                transport.emitAsync([0xE7, 0xF0, 0x33, 0x00, 1, 8])
                if !userInfoSent {
                    userInfoSent = true
                    // E7 34 total=1 current=1 uid=...65 name="CLE" year_off=100 (2000)
                    var record: [UInt8] = [0xE7, 0x34, 1, 1]
                    record += ScaleCodec.encodeUID(0x65)
                    record += Array("CLE".utf8)
                    record += [100] // 1900 + 100 = 2000
                    transport.emitAsync(record)
                }
            default:
                break
            }
        }
        let client = makeClient(transport)
        await client.start()
        try await client.initSession()
        let users = try await client.listUsers()

        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users[0].name, "CLE")
        XCTAssertEqual(users[0].year, 2000)
        XCTAssertEqual(users[0].uidHex, "0000000000000065")

        // The user record must have been auto-ACKed: E7 F1 <echo[1..3]>
        let acks = transport.written.filter { $0.count == 5 && $0[1] == 0xF1 }
        XCTAssertEqual(acks.count, 1)
        XCTAssertEqual(acks[0], [0xE7, 0xF1, 0x34, 1, 1])
    }

    // MARK: - getSavedMeasurements (2-part merge + ACKs)

    func testSavedMeasurementsTwoPartMerge() async throws {
        let transport = MockTransport()
        let payload = makePayload()
        let firstHalf = Array(payload[0..<8])
        let secondHalf = Array(payload[8...])

        transport.onWrite = { frame in
            switch frame.first {
            case 0xE6:
                transport.emitAsync([0xE6, 0x01])
            case 0xE7 where frame[1] == 0x41:
                // ACK: E7 F0 41 parts=2
                transport.emitAsync([0xE7, 0xF0, 0x41, 0x02])
                // Part 1 (odd): E7 42 total=2 received=1 + first half
                transport.emitAsync([0xE7, 0x42, 2, 1] + firstHalf)
                // Part 2 (even): E7 42 total=2 received=2 + second half
                transport.emitAsync([0xE7, 0x42, 2, 2] + secondHalf)
            default:
                break
            }
        }
        let client = makeClient(transport)
        await client.start()
        try await client.initSession()
        let measurements = try await client.getSavedMeasurements(uid: 0x65)

        XCTAssertEqual(measurements.count, 1)
        let m = measurements[0]
        XCTAssertEqual(m.timestamp, 0x6500_0001)
        XCTAssertEqual(m.weightKg, 70.0, accuracy: 0.001)
        XCTAssertEqual(m.impedance, 500)
        XCTAssertEqual(m.fatPct, 21.5, accuracy: 0.001)
        XCTAssertEqual(m.waterPct, 52.2, accuracy: 0.001)
        XCTAssertEqual(m.musclePct, 40.1, accuracy: 0.001)
        XCTAssertEqual(m.boneKg, 11.7, accuracy: 0.001)
        XCTAssertEqual(m.uid, "0000000000000065")

        // Both parts explicitly ACKed with E7 F1 echo of [1..3]
        let acks = transport.written.filter { $0.count == 5 && $0[1] == 0xF1 }
        XCTAssertEqual(acks.count, 2)
        XCTAssertEqual(acks[0], [0xE7, 0xF1, 0x42, 2, 1])
        XCTAssertEqual(acks[1], [0xE7, 0xF1, 0x42, 2, 2])
    }

    func testSavedMeasurementsEmpty() async throws {
        let transport = MockTransport()
        transport.onWrite = { frame in
            switch frame.first {
            case 0xE6:
                transport.emitAsync([0xE6, 0x01])
            case 0xE7 where frame[1] == 0x41:
                transport.emitAsync([0xE7, 0xF0, 0x41, 0x00]) // parts=0
            default:
                break
            }
        }
        let client = makeClient(transport)
        await client.start()
        try await client.initSession()
        let measurements = try await client.getSavedMeasurements(uid: 0x65)
        XCTAssertTrue(measurements.isEmpty)
    }

    // MARK: - liveMeasure

    func testLiveMeasureFullResult() async throws {
        let transport = MockTransport()
        let payload = makePayload()
        // Body-comp parts: part 1 = uid metadata, parts 2-3 = payload halves
        // part2 header: E7 59 total current=2 + payload[0..<8]
        // part3 header: E7 59 total current=3 + payload[8...]

        transport.onWrite = { frame in
            switch frame.first {
            case 0xE6:
                transport.emitAsync([0xE6, 0x01])
            case 0xE7 where frame[1] == 0x40:
                transport.emitAsync([0xE7, 0xF0, 0x40, 0x00]) // accepted
                // Live weight: E7 58 flag=1 weight=1390 (69.5 kg)
                transport.emitAsync([0xE7, 0x58, 0x01, 0x05, 0x6E])
                // Stable weight: flag=0
                transport.emitAsync([0xE7, 0x58, 0x00, 0x05, 0x78])
                // Measurement parts (total=3): part1 uid, part2/3 payload
                var part1: [UInt8] = [0xE7, 0x59, 3, 1, 0x00]
                part1 += ScaleCodec.encodeUID(0x65)
                transport.emitAsync(part1)
                transport.emitAsync([0xE7, 0x59, 3, 2] + Array(payload[0..<8]))
                transport.emitAsync([0xE7, 0x59, 3, 3] + Array(payload[8...]))
            default:
                break
            }
        }
        let client = makeClient(transport)
        await client.start()
        try await client.initSession()

        var liveWeights: [Double] = []
        let result = try await client.liveMeasure(uid: 0x65, hold: 3.0) { kg, _ in
            liveWeights.append(kg)
        }

        XCTAssertEqual(result.weights.count, 2)
        XCTAssertEqual(result.weights[0], 69.5, accuracy: 0.001)
        XCTAssertEqual(result.weights[1], 70.0, accuracy: 0.001)
        XCTAssertEqual(liveWeights.count, 2)

        let measurement = try XCTUnwrap(result.measurement)
        XCTAssertEqual(measurement.uid, "0000000000000065")
        XCTAssertEqual(measurement.weightKg, 70.0, accuracy: 0.001)
        XCTAssertEqual(measurement.impedance, 500)

        // 2 weight frames + 3 measurement parts all ACKed
        let acks = transport.written.filter { $0.count == 5 && $0[1] == 0xF1 }
        XCTAssertEqual(acks.count, 5)
    }

    func testLiveMeasureRejectedUser() async throws {
        let transport = MockTransport()
        transport.onWrite = { frame in
            switch frame.first {
            case 0xE6:
                transport.emitAsync([0xE6, 0x01])
            case 0xE7 where frame[1] == 0x40:
                transport.emitAsync([0xE7, 0xF0, 0x40, 0x01]) // rejected
            default:
                break
            }
        }
        let client = makeClient(transport)
        await client.start()
        try await client.initSession()

        do {
            _ = try await client.liveMeasure(uid: 0x99, hold: 1.0)
            XCTFail("expected rejection")
        } catch let SBF70Error.rejected(status, command) {
            XCTAssertEqual(status, 1)
            XCTAssertEqual(command, 0x40)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - deleteUser / deleteSaved

    func testDeleteUserAckStatus() async throws {
        let transport = MockTransport()
        transport.onWrite = { frame in
            switch frame.first {
            case 0xE6:
                transport.emitAsync([0xE6, 0x01])
            case 0xE7 where frame[1] == 0x32:
                transport.emitAsync([0xE7, 0xF0, 0x32, 0x00]) // ok
            default:
                break
            }
        }
        let client = makeClient(transport)
        await client.start()
        try await client.initSession()
        let ok = try await client.deleteUser(uid: 0x65)
        XCTAssertTrue(ok)
    }

    // MARK: - timeout

    func testTimeoutWhenScaleSilent() async throws {
        let transport = MockTransport()
        transport.onWrite = { frame in
            if frame == [0xE6, 0x01] {
                transport.emitAsync([0xE6, 0x01])
            }
            // no response to anything else
        }
        let client = makeClient(transport)
        await client.start()
        try await client.initSession()

        do {
            _ = try await client.getStatus()
            XCTFail("expected timeout")
        } catch SBF70Error.timeout {
            // expected
        }
    }
}
