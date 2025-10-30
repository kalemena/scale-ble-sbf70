import Foundation

/// Abstraction over the BLE link so `SBF70Client` can be tested without hardware.
///
/// Implementations deliver every notification payload from characteristic FFE1
/// into `notifications` and perform write-with-response on the same
/// characteristic.
public protocol ScaleTransport: AnyObject {
    /// Stream of raw notification payloads (one element per frame).
    var notifications: AsyncStream<[UInt8]> { get }

    /// Write with response to characteristic FFE1.
    func write(_ data: [UInt8]) async throws

    /// Stop notifications and drop the connection (best effort).
    func close() async
}
