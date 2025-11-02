import Foundation

/// Stateful BLE client for the Beurer/Sanitas FFE0/FFE1 protocol (SBF70).
///
/// Swift port of `Sbf70Client` in `tools/sbf70-cli/sbf70.py` — method names
/// and frame layouts mirror the Python original for easy cross-reference.
public actor SBF70Client {
    private let transport: ScaleTransport
    private let defaultTimeout: TimeInterval
    private let verbose: Bool

    private var buffer: [[UInt8]] = []
    private var pumpTask: Task<Void, Never>?
    private var isClosed = false

    public init(transport: ScaleTransport, timeout: TimeInterval = 10.0, verbose: Bool = false) {
        self.transport = transport
        self.defaultTimeout = timeout
        self.verbose = verbose
    }

    // MARK: - Frame pump

    /// Start consuming the notification stream. Call once after connecting.
    public func start() {
        guard pumpTask == nil else { return }
        let stream = transport.notifications
        pumpTask = Task { [weak self] in
            for await frame in stream {
                guard let self, !Task.isCancelled else { return }
                await self.enqueue(frame)
            }
            await self?.markDisconnected()
        }
    }

    private func enqueue(_ frame: [UInt8]) {
        if verbose {
            FileHandle.standardError.write(Data("[dbg] <- \(ScaleCodec.hex(frame))\n".utf8))
        }
        guard !isClosed else { return }
        buffer.append(frame)
    }

    private func markDisconnected() {
        isClosed = true
    }

    /// Drop any stale buffered notifications (mirrors the drain in init_session).
    private func drain() {
        buffer.removeAll()
    }

    private func log(_ message: String) {
        if verbose {
            FileHandle.standardError.write(Data("[dbg] \(message)\n".utf8))
        }
    }

    // MARK: - Low-level I/O

    private func write(_ frame: [UInt8]) async throws {
        if verbose {
            FileHandle.standardError.write(Data("[dbg] -> \(ScaleCodec.hex(frame))\n".utf8))
        }
        try await transport.write(frame)
    }

    /// E7 <cmd> <params...>
    private func cmd(_ command: UInt8, _ params: [UInt8] = []) -> [UInt8] {
        [ScaleStart.cmd, command] + params
    }

    /// Echo bytes [1..3] after APP_ACK (openScale / wiki) — sbf70.py:282-286.
    private func ack(_ frame: [UInt8]) async throws {
        guard frame.count >= 4 else { return }
        try await write([ScaleStart.cmd, ScaleCmd.appAck, frame[1], frame[2], frame[3]])
    }

    /// Poll the buffer for the next frame, with timeout (sbf70.py:288-311).
    private func nextFrame(timeout: TimeInterval) async throws -> [UInt8] {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            if isClosed { throw SBF70Error.disconnected }
            if !buffer.isEmpty {
                return buffer.removeFirst()
            }
            if ContinuousClock.now >= deadline {
                throw SBF70Error.timeout
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    /// Dequeue frames until `predicate` matches, optionally auto-ACKing
    /// streaming frames first (exact Python semantics, sbf70.py:288-311).
    private func wait(
        timeout: TimeInterval? = nil,
        autoAck: Bool = false,
        matching predicate: ([UInt8]) -> Bool
    ) async throws -> [UInt8] {
        let effectiveTimeout = timeout ?? defaultTimeout
        let deadline = ContinuousClock.now + .seconds(effectiveTimeout)
        while true {
            let remaining = deadline - .now
            guard remaining > .zero else { throw SBF70Error.timeout }
            let frame = try await nextFrame(timeout: remaining.timeInterval)
            if autoAck,
                frame.count >= 4,
                frame[0] == ScaleStart.cmd,
                ScaleCmd.streamingACK.contains(frame[1])
            {
                try await ack(frame)
            }
            if predicate(frame) {
                return frame
            }
        }
    }

    /// Wait for `E7 F0 <for_cmd> ...` (sbf70.py:536-543).
    private func waitScaleAck(for forCmd: UInt8, timeout: TimeInterval? = nil) async throws -> [UInt8] {
        try await wait(timeout: timeout) { frame in
            frame.count >= 4
                && frame[0] == ScaleStart.cmd
                && frame[1] == ScaleCmd.scaleAck
                && frame[2] == forCmd
        }
    }

    // MARK: - Session lifecycle (sbf70.py:242-324)

    /// Drain stale notifications, INIT (`E6 01`), then SET_TIME (`E9` + unix).
    ///
    /// The scale's app session lapses after a short inactivity window — a
    /// command sent against a stale session is silently ignored (no reply →
    /// timeout). The CLI always runs command batches against a freshly
    /// initialized session; call this before each batch, not just at connect.
    public func initSession() async throws {
        drain()

        try await write([ScaleStart.initSession, 0x01])
        _ = try await wait { $0.first == ScaleStart.initSession }

        let unix = UInt32(Date().timeIntervalSince1970)
        var setTime: [UInt8] = [ScaleStart.setTime]
        setTime.append(contentsOf: [
            UInt8(truncatingIfNeeded: unix >> 24),
            UInt8(truncatingIfNeeded: unix >> 16),
            UInt8(truncatingIfNeeded: unix >> 8),
            UInt8(truncatingIfNeeded: unix),
        ])
        try await write(setTime)
        // No ACK expected for SET_TIME (sbf70.py:321-324).
        try await Task.sleep(for: .milliseconds(150))
    }

    /// Graceful disconnect: `EA 02` then close the transport (sbf70.py:249-260).
    public func disconnect() async {
        try? await write([ScaleStart.disconnect, 0x02])
        await transport.close()
        isClosed = true
        pumpTask?.cancel()
    }

    // MARK: - Commands

    /// `E7 4F <uid8>` — battery / thresholds / unit / version (sbf70.py:326-345).
    public func getStatus(uid: UInt64 = 0) async throws -> ScaleStatus {
        try await write(cmd(ScaleCmd.scaleStatus, ScaleCodec.encodeUID(uid)))
        let frame = try await wait { f in
            f.count >= 12
                && f[0] == ScaleStart.cmd
                && f[1] == ScaleCmd.scaleAck
                && f[2] == ScaleCmd.scaleStatus
        }
        // E7 F0 4F <pad> bat thr_w thr_f unit uexist uref umeas ver
        return ScaleStatus(
            battery: Int(frame[4]),
            weightThresholdKg: Double(frame[5]) / 10.0,
            fatThreshold: Double(frame[6]) / 10.0,
            unit: ScaleUnit.name(for: frame[7]),
            userExists: frame[8] == 0,
            userRefWeightExists: frame[9] == 0,
            userMeasurementExists: frame[10] == 0,
            version: Int(frame[11])
        )
    }

    /// `E7 33` then N x `E7 34` user records, each auto-ACKed (sbf70.py:347-380).
    public func listUsers() async throws -> [ScaleUser] {
        try await write(cmd(ScaleCmd.userList))
        let ackFrame = try await wait { f in
            f.count >= 6
                && f[0] == ScaleStart.cmd
                && f[1] == ScaleCmd.scaleAck
                && f[2] == ScaleCmd.userList
        }
        let count = Int(ackFrame[4])
        log("user list: \(count)/\(ackFrame[5])")
        guard count > 0 else { return [] }

        var users: [ScaleUser] = []
        while users.count < count {
            let frame = try await wait(autoAck: true) { f in
                f.count >= 16
                    && f[0] == ScaleStart.cmd
                    && f[1] == ScaleCmd.userInfo
            }
            let total = Int(frame[2])
            let current = Int(frame[3])
            let uid = ScaleCodec.decodeUID(frame, 4)
            let name = ScaleCodec.decodeCString(frame, 12, maxLength: 3)
            let year = 1900 + Int(frame[15])
            users.append(
                ScaleUser(
                    uidHex: ScaleCodec.uidHex(uid),
                    name: name,
                    year: year,
                    index: current,
                    count: total
                )
            )
        }
        return users
    }

    /// `E7 36 <uid8>` — birthday / height / sex / activity (sbf70.py:382-407).
    public func userDetails(uid: UInt64) async throws -> ScaleUser {
        try await write(cmd(ScaleCmd.userDetails, ScaleCodec.encodeUID(uid)))
        let frame = try await wait { f in
            f.count >= 12
                && f[0] == ScaleStart.cmd
                && f[1] == ScaleCmd.scaleAck
                && f[2] == ScaleCmd.userDetails
        }
        guard frame[3] == 0 else {
            throw SBF70Error.rejected(status: frame[3], command: ScaleCmd.userDetails)
        }
        let name = ScaleCodec.decodeCString(frame, 4, maxLength: 3)
        let year = 1900 + Int(frame[7])
        let month = 1 + Int(frame[8])
        let day = Int(frame[9])
        let male = (frame[11] & 0xF0) != 0
        return ScaleUser(
            uidHex: ScaleCodec.uidHex(uid),
            name: name,
            year: year,
            birthday: String(format: "%04d-%02d-%02d", year, month, day),
            heightCm: Int(frame[10]),
            sex: male ? "male" : "female",
            activity: Int(frame[11] & 0x0F)
        )
    }

    /// `E7 41 <uid8>` then N x `E7 42` parts (odd=first half, even=second half),
    /// explicitly ACKed (sbf70.py:409-461).
    public func getSavedMeasurements(
        uid: UInt64,
        deleteAfter: Bool = false,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [ScaleMeasurement] {
        try await write(cmd(ScaleCmd.getSavedMeasurements, ScaleCodec.encodeUID(uid)))
        let ackFrame = try await wait { f in
            f.count >= 4
                && f[0] == ScaleStart.cmd
                && f[1] == ScaleCmd.scaleAck
                && f[2] == ScaleCmd.getSavedMeasurements
        }
        let parts = Int(ackFrame[3])
        log("saved measurement parts: \(parts)")
        guard parts > 0 else { return [] }

        var measurements: [ScaleMeasurement] = []
        var first: [UInt8]?
        var received = 0
        while received < parts {
            let frame = try await wait { f in
                f.count >= 5
                    && f[0] == ScaleStart.cmd
                    && f[1] == ScaleCmd.savedMeasurement
            }
            try await ack(frame)
            let total = Int(frame[2])
            received = Int(frame[3])
            let payload = Array(frame[4...])
            onProgress?(received, total)
            if received % 2 == 1 {
                first = payload
            } else {
                guard let firstHalf = first else {
                    log("got second part without first; skipping")
                    continue
                }
                first = nil
                do {
                    measurements.append(try ScaleMeasurement(payload: firstHalf + payload, uid: uid))
                } catch {
                    log("parse error: \(error)")
                }
            }
            if received == total {
                break
            }
        }

        if deleteAfter, !measurements.isEmpty {
            _ = try await deleteSavedMeasurements(uid: uid)
        }
        return measurements
    }

    /// `E7 43 <uid8>` — clear all saved history for one user (sbf70.py:545-553).
    public func deleteSavedMeasurements(uid: UInt64) async throws -> Bool {
        try await write(cmd(ScaleCmd.deleteSavedMeasurements, ScaleCodec.encodeUID(uid)))
        let ackFrame = try await waitScaleAck(for: ScaleCmd.deleteSavedMeasurements)
        return ackFrame[3] == 0
    }

    /// `E7 32 <uid8>` — remove a user profile (sbf70.py:605-611).
    public func deleteUser(uid: UInt64) async throws -> Bool {
        try await write(cmd(ScaleCmd.userDelete, ScaleCodec.encodeUID(uid)))
        let ackFrame = try await waitScaleAck(for: ScaleCmd.userDelete)
        return ackFrame[3] == 0
    }

    // MARK: - User creation

    public struct NewUser: Sendable {
        public var name: String
        public var birthYear: Int
        /// 1...12 (wire format stores 0...11).
        public var birthMonth: Int
        public var birthDay: Int
        public var heightCm: Int
        public var isMale: Bool
        /// Wire nibble 1...5 (openScale sends activityLevel + 1).
        public var activity: Int

        public init(
            name: String,
            birthYear: Int,
            birthMonth: Int,
            birthDay: Int,
            heightCm: Int,
            isMale: Bool,
            activity: Int
        ) {
            self.name = name
            self.birthYear = birthYear
            self.birthMonth = birthMonth
            self.birthDay = birthDay
            self.heightCm = heightCm
            self.isMale = isMale
            self.activity = activity
        }
    }

    /// `E7 31 <uid8> <name3> <year-1900> <month0-11> <day> <height> <sex|activity>`
    /// — port of openScale `createRemoteUser` (BeurerSanitasHandler.kt).
    ///
    /// `uid` must be new on the scale; openScale uses max(existing, 100) + 1.
    /// Waits for `E7 F0 31 status`; success = status 0.
    public func addUser(uid: UInt64, _ newUser: NewUser) async throws -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var nick = newUser.name.uppercased().unicodeScalars.filter { allowed.contains($0) }
            .prefix(3).map { UInt8($0.value) }
        while nick.count < 3 { nick.append(0) }

        let sex: UInt8 = newUser.isMale ? 0x80 : 0x00
        let activity = UInt8(min(max(newUser.activity, 1), 5))
        let frame =
            cmd(ScaleCmd.userAdd, ScaleCodec.encodeUID(uid))
            + nick
            + [
                UInt8(truncatingIfNeeded: newUser.birthYear - 1900),
                UInt8(newUser.birthMonth - 1),
                UInt8(newUser.birthDay),
                UInt8(newUser.heightCm),
                sex | activity,
            ]
        try await write(frame)
        let ackFrame = try await waitScaleAck(for: ScaleCmd.userAdd)
        return ackFrame[3] == 0
    }

    /// Pick the next free remote uid: max(existing, 100) + 1 (openScale rule).
    public static func nextRemoteUID(existing: [ScaleUser]) -> UInt64 {
        var maxUID: UInt64 = 100
        for user in existing {
            maxUID = max(maxUID, user.uid)
        }
        return maxUID + 1
    }

    /// Trigger a measurement for `uid`; collect live weights + body-comp if
    /// available (sbf70.py:463-534).
    ///
    /// Re-initializes the session first — DO_MEASUREMENT against a lapsed
    /// session gets no reply (the CLI always measures on a fresh session).
    public func liveMeasure(
        uid: UInt64,
        hold: TimeInterval = 30.0,
        onWeight: (@Sendable (_ kg: Double, _ stable: Bool) -> Void)? = nil
    ) async throws -> (weights: [Double], measurement: ScaleMeasurement?) {
        try await initSession()
        try await write(cmd(ScaleCmd.doMeasurement, ScaleCodec.encodeUID(uid)))
        let ackFrame = try await wait { f in
            f.count >= 4
                && f[0] == ScaleStart.cmd
                && f[1] == ScaleCmd.scaleAck
                && f[2] == ScaleCmd.doMeasurement
        }
        guard ackFrame[3] == 0 else {
            throw SBF70Error.rejected(status: ackFrame[3], command: ScaleCmd.doMeasurement)
        }

        var weights: [Double] = []
        let deadline = ContinuousClock.now + .seconds(hold)
        var parts: [Int: [UInt8]] = [:]
        var totalParts: Int?
        var measurementUID: UInt64?

        while ContinuousClock.now < deadline {
            let remaining = max(0.1, (deadline - .now).timeInterval)
            let frame: [UInt8]
            do {
                frame = try await nextFrame(timeout: remaining)
            } catch {
                break // timeout ends the hold window
            }
            guard frame.count >= 2, frame[0] == ScaleStart.cmd else { continue }

            switch frame[1] {
            case ScaleCmd.weightMeasurement where frame.count >= 5:
                try await ack(frame)
                // SBF70 compact: [E7 58 flag wh wl]
                let kg = ScaleCodec.kgFromRaw(frame, 3)
                let stable = frame[2] == 0
                weights.append((kg * 100).rounded() / 100)
                onWeight?((kg * 100).rounded() / 100, stable)

            case ScaleCmd.measurement where frame.count >= 4:
                try await ack(frame)
                let current = Int(frame[3])
                totalParts = Int(frame[2])
                if current == 1, frame.count >= 13 {
                    measurementUID = ScaleCodec.decodeUID(frame, 5)
                } else {
                    parts[current] = Array(frame[4...])
                }
                if let total = totalParts, current == total, !parts.isEmpty {
                    // Join parts 2..N (part 1 is UID metadata).
                    let ordered = parts.keys.sorted().filter { $0 >= 2 }.compactMap { parts[$0] }
                    guard !ordered.isEmpty else { break }
                    let merged = ordered.flatMap { $0 }
                    do {
                        let measurement = try ScaleMeasurement(
                            payload: merged,
                            uid: measurementUID ?? uid
                        )
                        return (weights, measurement)
                    } catch {
                        log("live compose parse error: \(error)")
                        return (weights, nil)
                    }
                }

            default:
                continue
            }
        }
        return (weights, nil)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
