import Sbf70Kit
import SwiftUI

/// User profiles stored on the scale: list, details, add (experimental), delete.
struct UsersView: View {
    @EnvironmentObject private var session: SessionViewModel
    @EnvironmentObject private var appSettings: AppSettings
    @StateObject private var model = UsersViewModel()
    @State private var showAddForm = false
    @State private var pendingDelete: ScaleUser?

    var body: some View {
        NavigationStack {
            List {
                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
                if let notice = model.noticeMessage {
                    Section {
                        Label(notice, systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }
                }

                if session.isReady {
                    if model.isLoading && model.users.isEmpty {
                        Section { ProgressView("Reading users from scale…") }
                    } else if model.users.isEmpty && model.errorMessage == nil {
                        Section {
                            ContentUnavailableView(
                                "No Users on Scale",
                                systemImage: "person.crop.circle.badge.plus",
                                description: Text("Add a user below, or create one with the vendor app.")
                            )
                        }
                    } else {
                        Section("On the scale") {
                            ForEach(model.users) { user in
                                userRow(user)
                            }
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            "Connect the Scale",
                            systemImage: "bolt.slash",
                            description: Text("User management needs a BLE connection. Connect from the Measure tab.")
                        )
                    }
                }
            }
            .navigationTitle("Users")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            if let client = session.client {
                                await model.refresh(client: client)
                            }
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(!session.isReady || model.isLoading)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddForm = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(!session.isReady)
                }
            }
            .sheet(isPresented: $showAddForm) {
                AddUserForm { newUser in
                    Task {
                        if let client = session.client {
                            await model.add(client: client, newUser)
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete \(pendingDelete?.displayName ?? "") from the scale?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let user = pendingDelete, let client = session.client else { return }
                    pendingDelete = nil
                    Task { await model.delete(client: client, user: user) }
                }
            } message: {
                Text("The profile and its saved measurements on the scale will be removed.")
            }
        }
        .onChange(of: session.state) { _, state in
            if case .ready = state {
                Task {
                    if let client = session.client {
                        await model.refresh(client: client)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func userRow(_ user: ScaleUser) -> some View {
        let detail = model.details[user.uidHex]
        Button {
            appSettings.settings.activeUidHex = user.uidHex
            Task { await appSettings.save() }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    HStack {
                        Text(user.name)
                            .foregroundStyle(.primary)
                            .fontWeight(.medium)
                        if appSettings.activeUidHex == user.uidHex {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    if let detail {
                        Text([
                            "\(user.year)",
                            detail.birthday ?? "",
                            detail.heightCm.map { "\($0) cm" } ?? "",
                            detail.sex ?? "",
                        ].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(user.year)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(user.displayName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                pendingDelete = user
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// Add-user form honoring scale constraints (3-char nickname, activity 1...5).
private struct AddUserForm: View {
    let onSubmit: (SBF70Client.NewUser) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var birthDate = Date(timeIntervalSince1970: 631_152_000) // 1990-01-01
    @State private var heightCm = 170
    @State private var isMale = true
    @State private var activity = 3

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nickname (3 chars)", text: $name)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The scale stores only 3 characters.")
                }

                Section("Profile") {
                    DatePicker("Birthday", selection: $birthDate, displayedComponents: .date)
                    Stepper("Height: \(heightCm) cm", value: $heightCm, in: 100...220)
                    Picker("Sex", selection: $isMale) {
                        Text("Male").tag(true)
                        Text("Female").tag(false)
                    }
                    Picker("Activity", selection: $activity) {
                        Text("1 (low)").tag(1)
                        Text("2").tag(2)
                        Text("3").tag(3)
                        Text("4").tag(4)
                        Text("5 (high)").tag(5)
                    }
                }

                Section {
                    Text("Experimental: the add-user frame is ported from openScale and is not yet verified on hardware. Prefer the vendor app if this fails.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let components = Calendar.current.dateComponents([.year, .month, .day], from: birthDate)
                        onSubmit(
                            SBF70Client.NewUser(
                                name: name,
                                birthYear: components.year ?? 1990,
                                birthMonth: components.month ?? 1,
                                birthDay: components.day ?? 1,
                                heightCm: heightCm,
                                isMale: isMale,
                                activity: activity
                            )
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
