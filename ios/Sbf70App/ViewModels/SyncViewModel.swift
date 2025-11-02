import Foundation
import Sbf70Kit

/// Pulls saved measurements from the scale into `JsonStore`.
@MainActor
final class SyncViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case syncing
        case done(inserted: Int, updated: Int, deletedOnScale: Bool)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progressText: String?
    @Published var deleteAfterSync: Bool = false

    func loadPreferences() async {
        let settings = (try? await JsonStore.shared.loadSettings()) ?? .init()
        deleteAfterSync = settings.deleteAfterSync
    }

    func sync(client: SBF70Client, uidHex: String) async {
        phase = .syncing
        progressText = "Contacting scale…"

        let uid = UInt64(uidHex, radix: 16) ?? 0
        do {
            // Re-init: the scale's session lapses after inactivity, and
            // stale-session commands are silently ignored (timeout).
            try await client.initSession()
            // Refresh status first — also acts as a wake/liveness check.
            _ = try await client.getStatus(uid: uid)

            let measurements = try await client.getSavedMeasurements(
                uid: uid,
                deleteAfter: deleteAfterSync,
                onProgress: { [weak self] received, total in
                    Task { @MainActor in
                        self?.progressText = "Receiving part \(received)/\(total)…"
                    }
                }
            )

            progressText = measurements.isEmpty ? nil : "Saving…"
            let result = try await JsonStore.shared.mergeMeasurements(uidHex: uidHex, new: measurements)

            var settings = (try? await JsonStore.shared.loadSettings()) ?? .init()
            settings.deleteAfterSync = deleteAfterSync
            settings.activeUidHex = uidHex
            try? await JsonStore.shared.saveSettings(settings)

            progressText = nil
            phase = .done(
                inserted: result.inserted,
                updated: result.updated,
                deletedOnScale: deleteAfterSync && !measurements.isEmpty
            )
        } catch {
            progressText = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func reset() {
        phase = .idle
        progressText = nil
    }
}
