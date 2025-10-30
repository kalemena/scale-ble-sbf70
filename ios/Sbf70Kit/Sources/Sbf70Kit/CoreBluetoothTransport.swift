import CoreBluetooth
import Foundation

/// CoreBluetooth implementation of `ScaleTransport` for characteristic FFE1.
///
/// Owns a `CBCentralManager`, connects to a peripheral, discovers the FFE0
/// service / FFE1 characteristic, and bridges notifications into the
/// `AsyncStream` consumed by `SBF70Client`.
public final class CoreBluetoothTransport: NSObject, ScaleTransport {
    public enum TransportError: Error, LocalizedError {
        case bluetoothUnavailable(CBManagerState)
        case serviceNotFound
        case characteristicNotFound
        case connectionFailed
        case writeFailed

        public var errorDescription: String? {
            switch self {
            case let .bluetoothUnavailable(state):
                switch state {
                case .unauthorized: return "Bluetooth permission denied. Enable it in Settings."
                case .poweredOff: return "Bluetooth is off. Turn it on and retry."
                default: return "Bluetooth is unavailable (state \(state.rawValue))."
                }
            case .serviceNotFound:
                return "Scale service FFE0 not found."
            case .characteristicNotFound:
                return "Scale characteristic FFE1 not found."
            case .connectionFailed:
                return "Could not connect to the scale. Wake it (step on it) and retry."
            case .writeFailed:
                return "BLE write failed."
            }
        }
    }

    public let notifications: AsyncStream<[UInt8]>

    private var notificationContinuation: AsyncStream<[UInt8]>.Continuation?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var discoverContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var notifyContinuation: CheckedContinuation<Void, Error>?

    /// Set when the peripheral disconnects unexpectedly while a write is in flight.
    private var isReady = false

    public override init() {
        var continuation: AsyncStream<[UInt8]>.Continuation?
        notifications = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        notificationContinuation = continuation
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Connect / disconnect

    public func connect(to peripheral: CBPeripheral) async throws {
        guard central.state == .poweredOn else {
            throw TransportError.bluetoothUnavailable(central.state)
        }
        self.peripheral = peripheral
        peripheral.delegate = self

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            central.connect(peripheral, options: nil)
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                discoverContinuation = continuation
                peripheral.discoverServices([CBUUID(string: ScaleGATT.serviceUUID)])
            }
            guard
                let service = peripheral.services?.first(where: {
                    $0.uuid == CBUUID(string: ScaleGATT.serviceUUID)
                })
            else {
                throw TransportError.serviceNotFound
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                discoverContinuation = continuation
                peripheral.discoverCharacteristics(
                    [CBUUID(string: ScaleGATT.characteristicUUID)],
                    for: service
                )
            }
            guard let characteristic else { throw TransportError.characteristicNotFound }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                notifyContinuation = continuation
                peripheral.setNotifyValue(true, for: characteristic)
            }
            isReady = true
        } catch {
            central.cancelPeripheralConnection(peripheral)
            throw error
        }
    }

    // MARK: - ScaleTransport

    public func write(_ data: [UInt8]) async throws {
        guard isReady, let peripheral, let characteristic else {
            throw TransportError.connectionFailed
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeContinuation = continuation
            peripheral.writeValue(Data(data), for: characteristic, type: .withResponse)
        }
    }

    public func close() async {
        isReady = false
        if let peripheral {
            if let characteristic {
                peripheral.setNotifyValue(false, for: characteristic)
            }
            central.cancelPeripheralConnection(peripheral)
        }
        notificationContinuation?.finish()
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            isReady = false
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connectContinuation?.resume(throwing: error ?? TransportError.connectionFailed)
        connectContinuation = nil
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        isReady = false
        if let writeContinuation {
            self.writeContinuation = nil
            writeContinuation.resume(throwing: TransportError.connectionFailed)
        }
        notificationContinuation?.finish()
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            discoverContinuation?.resume(throwing: error)
        } else if peripheral.services?.contains(where: { $0.uuid == CBUUID(string: ScaleGATT.serviceUUID) }) != true {
            discoverContinuation?.resume(throwing: TransportError.serviceNotFound)
        } else {
            discoverContinuation?.resume()
        }
        discoverContinuation = nil
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            discoverContinuation?.resume(throwing: error)
        } else if let found = service.characteristics?.first(where: {
            $0.uuid == CBUUID(string: ScaleGATT.characteristicUUID)
        }) {
            characteristic = found
            discoverContinuation?.resume()
        } else {
            discoverContinuation?.resume(throwing: TransportError.characteristicNotFound)
        }
        discoverContinuation = nil
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let value = characteristic.value else { return }
        notificationContinuation?.yield([UInt8](value))
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            writeContinuation?.resume(throwing: error)
        } else {
            writeContinuation?.resume()
        }
        writeContinuation = nil
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            notifyContinuation?.resume(throwing: error)
        } else {
            notifyContinuation?.resume()
        }
        notifyContinuation = nil
    }
}

// MARK: - Scanner

public struct FoundDevice: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let rssi: Int

    public init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

/// Scans for SBF70-family scales using the NAME_HINTS filter (sbf70.py:71-84, 623-641).
@MainActor
public final class ScaleScanner: NSObject, ObservableObject {
    @Published public private(set) var devices: [FoundDevice] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var bluetoothUnavailable = false

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func startScan(timeout: TimeInterval = 12.0) {
        guard central.state == .poweredOn else {
            bluetoothUnavailable = true
            return
        }
        bluetoothUnavailable = false
        devices = []
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.stopScan()
        }
    }

    public func stopScan() {
        central.stopScan()
        isScanning = false
    }

    public func peripheral(for id: UUID) -> CBPeripheral? {
        peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
    }
}

extension ScaleScanner: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothUnavailable = central.state != .poweredOn
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard ScaleNames.matches(name), let name else { return }
        peripherals[peripheral.identifier] = peripheral
        let device = FoundDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let existing = devices.firstIndex(where: { $0.id == device.id }) {
            devices[existing] = device
        } else {
            devices.append(device)
        }
    }
}
