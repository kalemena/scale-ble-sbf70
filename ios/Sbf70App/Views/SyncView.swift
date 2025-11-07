import Sbf70Kit
import SwiftUI

/// Pull saved measurements from the scale into local JSON storage.
struct SyncView: View {
    @EnvironmentObject private var session: SessionViewModel
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SyncViewModel()

    var body: some View {
        NavigationStack {
            List {
                if let uidHex = appSettings.activeUidHex {
                    Section {
                        LabeledContent("User", value: "uid \(uidHex)")
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            "No Active User",
                            systemImage: "person.crop.circle.badge.questionmark",
                            description: Text("Pick a user in Settings first.")
                        )
                    }
                }

                Section {
                    Toggle(isOn: $model.deleteAfterSync) {
                        VStack(alignment: .leading) {
                            Text("Delete from scale after sync")
                            Text("The scale stores only a few readings. Free them once safely imported.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: model.deleteAfterSync) { _, _ in
                        appSettings.settings.deleteAfterSync = model.deleteAfterSync
                        Task { await appSettings.save() }
                    }

                    Toggle(isOn: $model.discardNoImpedance) {
                        VStack(alignment: .leading) {
                            Text("Discard measures with no impedance")
                            Text("Skip weight-only readings that have no body composition.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: model.discardNoImpedance) { _, _ in
                        appSettings.settings.discardNoImpedance = model.discardNoImpedance
                        Task { await appSettings.save() }
                    }
                }

                if let uidHex = appSettings.activeUidHex {
                    Section {
                        Button {
                            Task { await model.sync(client: client, uidHex: uidHex) }
                        } label: {
                            if case .syncing = model.phase {
                                HStack {
                                    ProgressView()
                                    Text("Syncing…")
                                }
                            } else {
                                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled({ if case .syncing = model.phase { true } else { false } }())
                    }
                }

                statusSection
            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await model.loadPreferences()
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .syncing:
            Section {
                if let progress = model.progressText {
                    Label(progress, systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                }
            }
        case let .done(inserted, updated, deletedOnScale):
            Section("Result") {
                Label("\(inserted) new, \(updated) updated", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                if deletedOnScale {
                    Label("Cleared the synced readings from the scale", systemImage: "trash")
                        .foregroundStyle(.secondary)
                }
                Button("Done") { dismiss() }
            }
        case let .failed(message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    private var client: SBF70Client {
        session.client!
    }
}
