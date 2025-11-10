import Foundation
@testable import Sbf70Kit

/// Scriptable transport: records writes and yields canned responses.
final class MockTransport: ScaleTransport, @unchecked Sendable {
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

    /// Called for every write; use to emit scripted responses.
    var onWrite: (([UInt8]) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onWrite
        }
        set {
            lock.lock()
            _onWrite = newValue
            lock.unlock()
        }
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

    /// Yield in write order — the AsyncStream buffers until the pump consumes.
    func emit(_ frame: [UInt8]) {
        continuation.yield(frame)
    }

    func emitAsync(_ frame: [UInt8]) {
        emit(frame)
    }
}
