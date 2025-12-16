import Foundation
import Sbf70Kit

/// App-wide settings mirror, shared through the environment.
@MainActor
final class AppSettings: ObservableObject {
    @Published var settings: JsonStore.Settings = .init()
    @Published var goals: [String: JsonStore.UserGoals] = [:]

    func load() async {
        settings = (try? await JsonStore.shared.loadSettings()) ?? .init()
        goals = (try? await JsonStore.shared.loadGoals()) ?? [:]
    }

    func save() async {
        try? await JsonStore.shared.saveSettings(settings)
    }

    func setWeightGoal(uidHex: String, weightKg: Double?) async {
        var userGoals = goals[uidHex] ?? JsonStore.UserGoals()
        userGoals.weightKg = weightKg
        goals[uidHex] = userGoals
        try? await JsonStore.shared.saveGoals(goals)
    }

    var activeUidHex: String? { settings.activeUidHex }
}
