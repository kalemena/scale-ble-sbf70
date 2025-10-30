// Protocol smoke checks — runnable without Xcode: `swift run sbf70-smoke`.
// Mirrors the critical cases of the XCTest suite (which needs Xcode).
import Foundation
import Sbf70Kit

setbuf(stdout, nil)

// MARK: - Tiny harness

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if condition {
        print("  ok  - \(message)")
    } else {
        failures += 1
        print("  FAIL - \(message)")
    }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    check(lhs == rhs, "\(message) (got \(lhs), want \(rhs))")
}

// MARK: - Mock transport (mirrors MockTransport.swift)

final class SmokeTransport: ScaleTransport, @unchecked Sendable {
    let notifications: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let lock = NSLock()
    private var _written: [[UInt8]] = []
    private var _onWrite: (([UInt8]) -> Void)?

    var written: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return _written
    }

    var onWrite: (([UInt8]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onWrite }
        set { lock.lock(); _onWrite = newValue; lock.unlock() }
    }

    init() {
        var continuation: AsyncStream<[UInt8]>.Continuation?
        notifications = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation!
    }

    func write(_ data: [UInt8]) async throws {
        appendWritten(data)
        let handler = currentHandler()
        handler?(data)
    }

    private func appendWritten(_ data: [UInt8]) {
        lock.lock()
        _written.append(data)
        lock.unlock()
    }

    private func currentHandler() -> (([UInt8]) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return _onWrite
    }

    func close() async {
        continuation.finish()
    }

    func emit(_ frame: [UInt8]) {
        // Yield in write order — the AsyncStream buffers until the pump consumes.
        continuation.yield(frame)
    }
}

func makePayload() -> [UInt8] {
    // ts=0x65000001, weight=1400 (70.00 kg), Z=500, fat=21.5, water=52.2, muscle=40.1, bone=11.7
    [
        0x65, 0x00, 0x00, 0x01,
        0x05, 0x78,
        0x01, 0xF4,
        0x00, 0xD7,
        0x02, 0x0A,
        0x01, 0x91,
        0x00, 0xEA,
    ]
}

// MARK: - Codec checks

print("ScaleCodec:")
checkEqual(ScaleCodec.u16BE([0x12, 0x34], 0), 0x1234, "u16BE")
checkEqual(ScaleCodec.u32BE([0x65, 0x00, 0x00, 0x01], 0), 0x65000001, "u32BE")
checkEqual(ScaleCodec.kgFromRaw([0x05, 0x78], 0), 70.0, "kgFromRaw 1400 -> 70.0")
checkEqual(ScaleCodec.percentFromRaw([0x00, 0xD7], 0), 21.5, "percentFromRaw 215 -> 21.5")
checkEqual(ScaleCodec.encodeUID(0x65), [0, 0, 0, 0, 0, 0, 0, 0x65], "encodeUID")
checkEqual(ScaleCodec.decodeUID(ScaleCodec.encodeUID(0x65), 0), 0x65, "decodeUID roundtrip")
checkEqual(ScaleCodec.uidHex(0x65), "0000000000000065", "uidHex")
checkEqual(ScaleCodec.parseUID("00:00:00:00:00:00:00:65"), 0x65, "parseUID")
check(ScaleNames.matches("SANITAS SBF70"), "name hint SBF70")
check(!ScaleNames.matches("Mi Band"), "name hint reject")

let measurement = try! ScaleMeasurement(payload: makePayload(), uid: 0x65)
checkEqual(measurement.timestamp, 0x65000001, "measurement timestamp")
checkEqual(measurement.weightKg, 70.0, "measurement weight")
checkEqual(measurement.impedance, 500, "measurement impedance")
checkEqual(measurement.fatPct, 21.5, "measurement fat")
checkEqual(measurement.boneKg, 11.7, "measurement bone")
check(measurement.timeISO.hasSuffix("+00:00"), "measurement time_iso UTC format")

// MARK: - Client: initSession + status

print("SBF70Client initSession/getStatus:")
let statusTransport = SmokeTransport()
statusTransport.onWrite = { frame in
    if frame == [0xE6, 0x01] {
        statusTransport.emit([0xE6, 0x01])
    } else if frame.first == 0xE7, frame.count >= 10, frame[1] == 0x4F {
        statusTransport.emit([0xE7, 0xF0, 0x4F, 0x00, 92, 40, 0xDC, 0x01, 0x00, 0x00, 0x00, 0x05])
    }
}
let statusClient = SBF70Client(transport: statusTransport, timeout: 2.0)
await statusClient.start()
try! await statusClient.initSession()
checkEqual(statusTransport.written.first, [0xE6, 0x01], "INIT first")
checkEqual(statusTransport.written.count, 2, "INIT + SET_TIME only")
checkEqual(statusTransport.written[1].first, 0xE9, "SET_TIME start byte")

let status = try! await statusClient.getStatus(uid: 0x65)
checkEqual(status.battery, 92, "status battery")
checkEqual(status.unit, "kg", "status unit")
checkEqual(status.version, 5, "status version")
check(status.userExists, "status userExists")

// MARK: - Client: listUsers auto-ACK

print("SBF70Client listUsers:")
let usersTransport = SmokeTransport()
usersTransport.onWrite = { frame in
    if frame == [0xE6, 0x01] {
        usersTransport.emit([0xE6, 0x01])
    } else if frame.first == 0xE7, frame.count >= 2, frame[1] == 0x33 {
        usersTransport.emit([0xE7, 0xF0, 0x33, 0x00, 1, 8])
        var record: [UInt8] = [0xE7, 0x34, 1, 1]
        record += ScaleCodec.encodeUID(0x65)
        record += Array("CLE".utf8)
        record += [100]
        usersTransport.emit(record)
    }
}
let usersClient = SBF70Client(transport: usersTransport, timeout: 2.0)
await usersClient.start()
try! await usersClient.initSession()
let users = try! await usersClient.listUsers()
checkEqual(users.count, 1, "one user")
checkEqual(users.first?.name, "CLE", "user name")
checkEqual(users.first?.year, 2000, "user year")
let userAcks = usersTransport.written.filter { $0.count == 5 && $0[1] == 0xF1 }
checkEqual(userAcks.count, 1, "user record auto-ACKed once")
checkEqual(userAcks.first, [0xE7, 0xF1, 0x34, 1, 1], "user ACK echo bytes")

// MARK: - Client: saved measurements 2-part merge

print("SBF70Client getSavedMeasurements:")
let historyTransport = SmokeTransport()
let payload = makePayload()
historyTransport.onWrite = { frame in
    if frame == [0xE6, 0x01] {
        historyTransport.emit([0xE6, 0x01])
    } else if frame.first == 0xE7, frame.count >= 2, frame[1] == 0x41 {
        historyTransport.emit([0xE7, 0xF0, 0x41, 0x02])
        historyTransport.emit([0xE7, 0x42, 2, 1] + Array(payload[0..<8]))
        historyTransport.emit([0xE7, 0x42, 2, 2] + Array(payload[8...]))
    }
}
let historyClient = SBF70Client(transport: historyTransport, timeout: 2.0)
await historyClient.start()
try! await historyClient.initSession()
let measurements = try! await historyClient.getSavedMeasurements(uid: 0x65)
checkEqual(measurements.count, 1, "one merged measurement")
checkEqual(measurements.first?.weightKg, 70.0, "merged weight")
checkEqual(measurements.first?.impedance, 500, "merged impedance")
let historyAcks = historyTransport.written.filter { $0.count == 5 && $0[1] == 0xF1 }
checkEqual(historyAcks.count, 2, "both parts ACKed")
checkEqual(historyAcks.first, [0xE7, 0xF1, 0x42, 2, 1], "part 1 ACK echo")

// MARK: - Client: live measure

print("SBF70Client liveMeasure:")
let liveTransport = SmokeTransport()
liveTransport.onWrite = { frame in
    if frame == [0xE6, 0x01] {
        liveTransport.emit([0xE6, 0x01])
    } else if frame.first == 0xE7, frame.count >= 2, frame[1] == 0x40 {
        liveTransport.emit([0xE7, 0xF0, 0x40, 0x00])
        liveTransport.emit([0xE7, 0x58, 0x01, 0x05, 0x6E]) // 69.5 live
        liveTransport.emit([0xE7, 0x58, 0x00, 0x05, 0x78]) // 70.0 stable
        var part1: [UInt8] = [0xE7, 0x59, 3, 1, 0x00]
        part1 += ScaleCodec.encodeUID(0x65)
        liveTransport.emit(part1)
        liveTransport.emit([0xE7, 0x59, 3, 2] + Array(payload[0..<8]))
        liveTransport.emit([0xE7, 0x59, 3, 3] + Array(payload[8...]))
    }
}
let liveClient = SBF70Client(transport: liveTransport, timeout: 2.0)
await liveClient.start()
try! await liveClient.initSession()
let live = try! await liveClient.liveMeasure(uid: 0x65, hold: 3.0)
checkEqual(live.weights.count, 2, "two live weights")
checkEqual(live.weights[0], 69.5, "live weight value")
let liveMeasurement = live.measurement
check(liveMeasurement != nil, "live measurement composed")
checkEqual(liveMeasurement?.uid, "0000000000000065", "live measurement uid")
checkEqual(liveMeasurement?.weightKg, 70.0, "live measurement weight")
let liveAcks = liveTransport.written.filter { $0.count == 5 && $0[1] == 0xF1 }
checkEqual(liveAcks.count, 5, "2 weights + 3 parts ACKed")

// MARK: - JsonStore

print("JsonStore:")
let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("sbf70-smoke-\(UUID().uuidString)", isDirectory: true)
let store = JsonStore(directory: tempDir)
let sample = ScaleMeasurement(
    timestamp: 100, timeISO: "x", weightKg: 70, impedance: 500,
    fatPct: 21.5, waterPct: 52, musclePct: 40, boneKg: 11.7, uid: "0000000000000065"
)
let merge1 = try! await store.mergeMeasurements(uidHex: "0000000000000065", new: [sample])
checkEqual(merge1.inserted, 1, "merge inserts new")
var updatedSample = sample
updatedSample.weightKg = 71
let merge2 = try! await store.mergeMeasurements(uidHex: "0000000000000065", new: [updatedSample])
checkEqual(merge2.updated, 1, "merge dedupes by timestamp")
let stored = try! await store.loadMeasurements(uidHex: "0000000000000065")
checkEqual(stored.first?.weightKg, 71, "merged value wins")
try? FileManager.default.removeItem(at: tempDir)

// MARK: - Summary

print("")
print("\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    exit(1)
}
