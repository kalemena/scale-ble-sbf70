import Foundation
import Sbf70Kit

/// Reads/creates/deletes user profiles stored on the scale.
@MainActor
final class UsersViewModel: ObservableObject {
    @Published private(set) var users: [ScaleUser] = []
    @Published private(set) var details: [String: ScaleUser] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    func refresh(client: SBF70Client) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await client.initSession() // stale sessions time out (see SBF70Client.initSession)
            let listed = try await client.listUsers()
            var detailed: [String: ScaleUser] = [:]
            for user in listed {
                if let full = try? await client.userDetails(uid: user.uid) {
                    detailed[user.uidHex] = full
                } else {
                    detailed[user.uidHex] = user
                }
            }
            users = listed
            details = detailed
            try await JsonStore.shared.saveUsers(listed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(client: SBF70Client, user: ScaleUser) async {
        errorMessage = nil
        noticeMessage = nil
        do {
            try await client.initSession()
            let ok = try await client.deleteUser(uid: user.uid)
            if ok {
                noticeMessage = "Deleted \(user.name) from the scale."
                await refresh(client: client)
            } else {
                errorMessage = "Scale rejected the delete."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Experimental — frame layout ported from openScale, not yet verified on hardware.
    func add(client: SBF70Client, _ newUser: SBF70Client.NewUser) async {
        errorMessage = nil
        noticeMessage = nil
        do {
            try await client.initSession()
            let listed = try await client.listUsers()
            let uid = SBF70Client.nextRemoteUID(existing: listed)
            let ok = try await client.addUser(uid: uid, newUser)
            if ok {
                noticeMessage = "Added \(newUser.name.uppercased()) to the scale."
                await refresh(client: client)
            } else {
                errorMessage = "Scale rejected the new user (status != 0)."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
