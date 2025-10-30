import CoreBluetooth
import Foundation
import Sbf70Kit

/// Owns the single connected `SBF70Client` session shared by all screens.
@MainActor
final class SessionViewModel: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var deviceName: String?

    private(set) var client: SBF70Client?
    private var transport: CoreBluetoothTransport?

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    func connect(to peripheral: CBPeripheral) async {
        state = .connecting
        deviceName = peripheral.name
        let newTransport = CoreBluetoothTransport()
        do {
            try await newTransport.connect(to: peripheral)
            let newClient = SBF70Client(transport: newTransport, timeout: 10)
            await newClient.start()
            try await newClient.initSession()
            transport = newTransport
            client = newClient
            state = .ready

            var settings = (try? await JsonStore.shared.loadSettings()) ?? .init()
            settings.lastPeripheralUUID = peripheral.identifier.uuidString
            settings.lastDeviceName = peripheral.name
            try? await JsonStore.shared.saveSettings(settings)
        } catch {
            await newTransport.close()
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        let oldClient = client
        Task { await oldClient?.disconnect() }
        client = nil
        transport = nil
        state = .disconnected
        deviceName = nil
    }
}
