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

    func connect(id: UUID, name: String?) async {
        state = .connecting
        deviceName = name
        let newTransport = CoreBluetoothTransport()
        do {
            // Transport re-vends the peripheral from its own central manager.
            try await newTransport.connect(to: id)
            let newClient = SBF70Client(transport: newTransport, timeout: 10)
            await newClient.start()
            try await newClient.initSession()
            // Pull the user directory before announcing readiness so other
            // screens don't issue concurrent commands on this session.
            await syncUsers(newClient)
            transport = newTransport
            client = newClient
            state = .ready

            var settings = (try? await JsonStore.shared.loadSettings()) ?? .init()
            settings.lastPeripheralUUID = id.uuidString
            settings.lastDeviceName = name
            try? await JsonStore.shared.saveSettings(settings)
        } catch {
            await newTransport.close()
            state = .failed(error.localizedDescription)
        }
    }

    /// Best-effort refresh of the cached user directory right after connecting.
    private func syncUsers(_ client: SBF70Client) async {
        do {
            let listed = try await client.listUsers()
            var detailed: [ScaleUser] = []
            detailed.reserveCapacity(listed.count)
            for user in listed {
                guard let details = try? await client.userDetails(uid: user.uid) else {
                    detailed.append(user)
                    continue
                }
                var merged = user
                merged.birthday = details.birthday
                merged.heightCm = details.heightCm
                merged.sex = details.sex
                merged.activity = details.activity
                detailed.append(merged)
            }
            try await JsonStore.shared.saveUsers(detailed)
        } catch {
            // User sync should never prevent the scale from being usable.
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
