import Sbf70Kit
import SwiftUI

struct RootView: View {
    @StateObject private var session = SessionViewModel()
    @StateObject private var appSettings = AppSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            measureTab
                .tabItem { Label("Measure", systemImage: "scalemass") }
            HistoryView()
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
            UsersView()
                .tabItem { Label("Users", systemImage: "person.2") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .environmentObject(session)
        .environmentObject(appSettings)
        .task {
            await appSettings.load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, session.isReady {
                // The scale sleeps on its own; drop our side cleanly too.
                session.disconnect()
            }
        }
    }

    @ViewBuilder
    private var measureTab: some View {
        NavigationStack {
            Group {
                if session.isReady {
                    MeasureConnectedView()
                } else {
                    ScannerView()
                }
            }
            .navigationTitle("Scale")
        }
    }
}

/// Header + live measure + sync entry point shown while connected.
struct MeasureConnectedView: View {
    @EnvironmentObject private var session: SessionViewModel
    @State private var showSync = false

    var body: some View {
        LiveMeasureView()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSync = true
                    } label: {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        session.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "bolt.slash")
                    }
                }
            }
            .sheet(isPresented: $showSync) {
                SyncView()
            }
    }
}
