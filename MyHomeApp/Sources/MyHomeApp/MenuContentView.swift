// baseline-guard:allow rewrite of existing menu view to use rich DPS state
import AppKit
import SwiftUI
import MyHomeCore

struct MenuContentView: View {
    @EnvironmentObject private var store: DeviceStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.headerText)
                .font(.headline)
                .padding(.horizontal, 4)

            Divider()

            if store.devices.isEmpty {
                HStack(spacing: 8) {
                    if store.isWorking {
                        ProgressView().controlSize(.small)
                    }
                    Text(store.isWorking ? "Loading devices…" : "No devices loaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.horizontal, 4)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.devices) { device in
                            DeviceRow(device: device)
                        }
                    }
                }
                .frame(maxHeight: 420)
            }

            if let error = store.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
            }

            Divider()

            HStack(spacing: 12) {
                Button("Open MyHome") {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Rescan") {
                    Task { await store.rescan() }
                }
                .disabled(store.isWorking)
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(12)
        .frame(width: 340)
        .task {
            if store.devices.isEmpty {
                await store.refresh()
            }
        }
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
    }
}

struct DeviceRow: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device

    private var isEnabled: Bool { device.hasAddress }

    private var power: Bool? { store.power(for: device) }

    private var subtitle: String {
        let state = store.state(for: device)
        if device.kind == .plug, let watts = state.wattsText {
            return watts
        }
        if device.kind == .climate, let temperature = state.temperature {
            return "\(DPSValue.format(temperature)) °C"
        }
        return isEnabled ? device.ip : "Offline"
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { store.power(for: device) ?? false },
            set: { newValue in
                Task { await store.toggle(device, to: newValue) }
            }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.kind.iconName)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22)
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!isEnabled || power == nil)
                .opacity(power == nil ? 0.5 : 1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: store.isOn[device.id])
    }
}
