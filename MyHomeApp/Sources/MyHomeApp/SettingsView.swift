// baseline-guard:allow new settings source, no prior baseline
import SwiftUI
import ServiceManagement
import MyHomeCore

/// Native Settings window (macOS Settings scene). Three tabs: cloud
/// credentials, control cadence, and general preferences.
struct SettingsView: View {
    var body: some View {
        TabView {
            CloudSettingsView()
                .tabItem { Label("Cloud", systemImage: "cloud") }
            ControlSettingsView()
                .tabItem { Label("Control", systemImage: "slider.horizontal.3") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 540, height: 360)
    }
}

// MARK: - Cloud

private struct CloudSettingsView: View {
    private enum Status: Equatable {
        case idle
        case working
        case success(String)
        case failure(String)
    }

    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var maskedSecret = ""
    @State private var apiRegion = "eu"
    @State private var status: Status = .idle

    private let regions = ["cn", "us", "eu", "sg", "in"]

    var body: some View {
        Form {
            Section {
                TextField("Access ID", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                SecureField(
                    "Access Secret",
                    text: $apiSecret,
                    prompt: Text(maskedSecret.isEmpty ? "Required" : "Leave blank to keep \(maskedSecret)")
                )
                .textFieldStyle(.roundedBorder)
                Picker("Region", selection: $apiRegion) {
                    ForEach(regions, id: \.self) { region in
                        Text(regionLabel(region)).tag(region)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Tuya Cloud")
            } footer: {
                Text("Credentials are validated against the cloud before they are saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Button("Test & Save") { testAndSave() }
                        .disabled(status == .working)
                    if status == .working {
                        ProgressView().controlSize(.small)
                    }
                    statusText
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .task { await loadConfig() }
    }

    @ViewBuilder private var statusText: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working:
            Text("Testing against Tuya Cloud…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func regionLabel(_ region: String) -> String {
        region == "sg" ? "sg (Southeast Asia)" : region
    }

    private func loadConfig() async {
        do {
            let reply = try await BridgeClient.shared.request(["cmd": "config"])
            guard reply["ok"] as? Bool == true,
                  let config = reply["config"] as? [String: Any] else {
                throw BridgeError.badResponse("missing config")
            }
            apiKey = config["apiKey"] as? String ?? ""
            maskedSecret = config["apiSecretMasked"] as? String ?? ""
            let region = config["apiRegion"] as? String ?? ""
            if !region.isEmpty { apiRegion = region }
            status = .idle
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func testAndSave() {
        status = .working
        var payload: [String: Any] = [
            "cmd": "setconfig",
            "apiKey": apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "apiRegion": apiRegion
        ]
        // Empty secret = keep the stored one; the bridge tests with it and never
        // echoes it back.
        let trimmedSecret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty { payload["apiSecret"] = trimmedSecret }

        Task {
            do {
                let reply = try await BridgeClient.shared.request(payload, timeout: 30)
                if reply["ok"] as? Bool == true {
                    apiSecret = ""
                    status = .success("Connection verified — credentials saved.")
                    await loadConfig()
                } else {
                    status = .failure(reply["error"] as? String ?? "Cloud test failed.")
                }
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - Control

private struct ControlSettingsView: View {
    @AppStorage("pollIntervalSeconds") private var pollInterval = AppSettings.defaultPollInterval
    @AppStorage("scanWindowSeconds") private var scanWindow = AppSettings.defaultScanWindow

    var body: some View {
        Form {
            Section {
                Stepper("Poll interval: \(pollInterval)s", value: $pollInterval, in: AppSettings.pollIntervalRange)
                Stepper("Scan window: \(scanWindow)s", value: $scanWindow, in: AppSettings.scanWindowRange)
            } header: {
                Text("Polling")
            } footer: {
                Text("Poll interval applies the next time polling starts. Scan window applies to the next Rescan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bridge") {
                let path = BridgeClient.bridgeDirectory().appendingPathComponent("bridge.py").path
                Text(path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage("notifyOnDeviceOffline") private var notifyOffline = false
    @State private var launchAtLogin = false
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                if launchError == nil {
                    Text("MyHome starts in the menu bar when you log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Notifications on device offline (beta)", isOn: $notifyOffline)
            } footer: {
                Text("Stores the preference now; notification delivery ships in a later update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
