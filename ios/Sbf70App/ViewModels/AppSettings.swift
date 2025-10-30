import Foundation
import Sbf70Kit

/// App-wide settings mirror, shared through the environment.
@MainActor
final class AppSettings: ObservableObject {
    @Published var settings: JsonStore.Settings = .init()

    func load() async {
        settings = (try? await JsonStore.shared.loadSettings()) ?? .init()
    }

    func save() async {
        try? await JsonStore.shared.saveSettings(settings)
    }

    var activeUidHex: String? { settings.activeUidHex }
}
