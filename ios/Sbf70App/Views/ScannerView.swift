import CoreBluetooth
import Sbf70Kit
import SwiftUI

/// Scan for the scale; the user must wake it (step on it) first.
struct ScannerView: View {
    @EnvironmentObject private var session: SessionViewModel
    @EnvironmentObject private var appSettings: AppSettings
    @StateObject private var scanner = ScaleScanner()
    @State private var connectingID: UUID?

    var body: some View {
        List {
            Section {
                Label {
                    Text("Step on the scale to wake it, then tap Scan.\nKeep the app open — the scale sleeps after ~15 seconds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "figure.stand")
                        .font(.title2)
                }
                .padding(.vertical, 4)
            }

            if scanner.bluetoothUnavailable {
                Section {
                    ContentUnavailableView(
                        "Bluetooth Unavailable",
                        systemImage: "bolt.slash.fill",
                        description: Text("Enable Bluetooth in Settings to find the scale.")
                    )
                }
            }

            if case let .failed(message) = session.state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if !scanner.devices.isEmpty {
                Section("Found scales") {
                    ForEach(scanner.devices) { device in
                        Button {
                            connect(to: device)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                        .foregroundStyle(.primary)
                                    Text(device.id.uuidString)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if connectingID == device.id || session.state == .connecting {
                                    ProgressView()
                                } else {
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .disabled(connectingID != nil || session.state == .connecting)
                    }
                }
            } else if !scanner.isScanning && !scanner.bluetoothUnavailable {
                Section {
                    ContentUnavailableView(
                        "No Scale Found",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Wake the scale and tap Scan.")
                    )
                }
            }
        }
        .navigationTitle("Connect")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    scanner.startScan()
                } label: {
                    if scanner.isScanning {
                        ProgressView()
                    } else {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                }
                .disabled(scanner.isScanning)
            }
        }
        .overlay(alignment: .bottom) {
            if scanner.isScanning {
                Text("Scanning… step on the scale now")
                    .font(.footnote)
                    .padding(10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        }
        .onAppear {
            if !scanner.isScanning, scanner.devices.isEmpty {
                scanner.startScan()
            }
        }
    }

    private func connect(to device: FoundDevice) {
        connectingID = device.id
        scanner.stopScan()
        Task {
            await session.connect(id: device.id, name: device.name)
            connectingID = nil
            if session.isReady {
                appSettings.settings.lastPeripheralUUID = device.id.uuidString
                appSettings.settings.lastDeviceName = device.name
                await appSettings.save()
            }
        }
    }
}
