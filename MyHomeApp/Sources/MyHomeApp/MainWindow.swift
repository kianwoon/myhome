// baseline-guard:allow new main window source, no prior baseline
import AppKit
import SwiftUI
import MyHomeCore

enum DeviceGroup: String, CaseIterable, Identifiable {
    case fans, curtains, lights, plugs, climate, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fans: return "Fans"
        case .curtains: return "Curtains"
        case .lights: return "Lights"
        case .plugs: return "Plugs"
        case .climate: return "Climate"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .fans: return "fanblades"
        case .curtains: return "curtains.closed"
        case .lights: return "lightbulb"
        case .plugs: return "powerplug"
        case .climate: return "thermometer.medium"
        case .other: return "square.grid.2x2"
        }
    }

    func contains(_ device: Device) -> Bool {
        switch self {
        case .fans: return device.kind == .fan
        case .curtains: return device.kind == .curtain
        case .lights: return device.kind == .light
        case .plugs: return device.kind == .plug
        case .climate: return device.kind == .climate
        case .other:
            return ![DeviceKind.fan, .curtain, .light, .plug, .climate].contains(device.kind)
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var group: DeviceGroup = .fans
    @State private var selectedID: String?

    private var filtered: [Device] {
        store.devices.filter { group.contains($0) }
    }

    private var selectedDevice: Device? {
        store.devices.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            List(DeviceGroup.allCases, selection: $group) { item in
                Label(item.title, systemImage: item.icon)
                    .badge(store.devices.filter { item.contains($0) }.count)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 175)
            .navigationTitle("MyHome")
        } content: {
            ScrollView {
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: group.icon)
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No devices in \(group.title).")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(filtered) { device in
                            DeviceCard(
                                device: device,
                                isSelected: selectedID == device.id
                            ) {
                                selectedID = device.id
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationSplitViewColumnWidth(min: 480, ideal: 580)
            .navigationTitle(group.title)
        } detail: {
            if let device = selectedDevice {
                DeviceDetailView(device: device)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "hand.tap")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Select a device to inspect its DPS.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if store.devices.isEmpty {
                await store.refresh()
            }
            await store.loadAllStatuses()
        }
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
    }
}

// MARK: - Card

struct DeviceCard: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let isSelected: Bool
    let onSelect: () -> Void

    private var isEnabled: Bool { device.hasAddress }

    private var power: Bool? { store.power(for: device) }

    private var powerBinding: Binding<Bool> {
        Binding(
            get: { store.power(for: device) ?? false },
            set: { newValue in
                Task { await store.toggle(device, to: newValue) }
            }
        )
    }

    private func summary(_ state: DeviceState) -> String {
        if !isEnabled { return "Offline" }
        switch device.kind {
        case .plug:
            if let watts = state.wattsText { return watts }
        case .climate:
            if let temperature = state.temperature {
                return "\(DPSValue.format(temperature)) °C"
            }
        case .fan:
            return "Speed \(state.fanSpeed)"
        case .curtain:
            if let position = state.position { return "\(Int(position.rounded())) %" }
        case .light:
            if let brightness = state.brightness { return "Brightness \(Int(brightness.rounded()))" }
        default:
            break
        }
        return device.kind.label
    }

    var body: some View {
        let state = store.state(for: device)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: device.kind.iconName)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 26)
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(summary(state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Toggle("", isOn: powerBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!isEnabled || power == nil)
                    .opacity(power == nil ? 0.5 : 1)
            }

            SpecControlsView(device: device, state: state)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            RichControlView(device: device, state: state)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .opacity(isEnabled ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Rich controls

struct RichControlView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let state: DeviceState

    var body: some View {
        switch device.kind {
        case .fan:
            FanControlView(device: device, state: state)
        case .curtain:
            CurtainControlView(device: device, state: state)
        case .light:
            LightControlView(device: device, state: state)
        case .plug:
            PlugReadoutView(state: state)
        case .climate:
            ClimateChipsView(state: state)
        default:
            RawPreviewView(state: state, kind: device.kind)
        }
    }
}

struct FanControlView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let state: DeviceState

    private var speedKey: String { state.fanSpeedKey ?? "2" }
    private var showSpeed: Bool { !state.isDeclared(state.fanSpeedKey) }
    private var showOscillation: Bool { !state.isDeclared(state.oscillationKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showSpeed {
                HStack(spacing: 8) {
                    Text("Speed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach(1...state.fanSpeedMax, id: \.self) { level in
                        Button {
                            Task {
                                await store.setDps(
                                    device,
                                    [speedKey: level],
                                    optimistic: [speedKey: .number(Double(level))]
                                )
                            }
                        } label: {
                            Circle()
                                .fill(level <= state.fanSpeed
                                      ? Color.accentColor
                                      : Color.secondary.opacity(0.25))
                                .frame(width: 10, height: 10)
                        }
                        .buttonStyle(.plain)
                        .help("Speed \(level)")
                    }
                }
            }

            if showOscillation, let oscKey = state.oscillationKey {
                Toggle(isOn: Binding(
                    get: { store.state(for: device).oscillation },
                    set: { newValue in
                        Task {
                            await store.setDps(
                                device,
                                [oscKey: newValue],
                                optimistic: [oscKey: .bool(newValue)]
                            )
                        }
                    }
                )) {
                    Text("Oscillate")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
    }
}

struct CurtainControlView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let state: DeviceState

    @State private var position: Double = 0
    @State private var isDragging = false
    private var showPosition: Bool { !state.isDeclared(state.curtainPositionKey) }
    private var showActions: Bool { !state.isDeclared(state.curtainActionKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showPosition {
                HStack(spacing: 8) {
                    Text("Position")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $position, in: 0...100, onEditingChanged: { editing in
                        isDragging = editing
                        if !editing, let positionKey = state.curtainPositionKey {
                            Task {
                                await store.setDps(device, [positionKey: Int(position.rounded())])
                            }
                        }
                    })
                    .controlSize(.mini)
                    .disabled(state.curtainPositionKey == nil)
                    Text("\(Int(position.rounded())) %")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }

            if showActions {
                if let actionKey = state.curtainActionKey {
                    HStack(spacing: 6) {
                        actionButton("Open", icon: "arrow.up.to.line", value: "open", key: actionKey)
                        actionButton("Stop", icon: "stop.fill", value: "stop", key: actionKey)
                        actionButton("Close", icon: "arrow.down.to.line", value: "close", key: actionKey)
                    }
                } else {
                    Text("Action control unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { position = state.position ?? 0 }
        .onChange(of: state.position ?? 0) { newValue in
            if !isDragging {
                position = newValue
            }
        }
    }

    private func actionButton(_ title: String, icon: String, value: String, key: String) -> some View {
        Button {
            Task {
                await store.setDps(
                    device,
                    [key: value],
                    optimistic: [key: .string(value)]
                )
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.caption2)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct LightControlView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let state: DeviceState

    @State private var brightness: Double = 500
    @State private var colorTemp: Double = 500
    @State private var isDraggingBrightness = false
    @State private var isDraggingTemp = false
    private var showBrightness: Bool { !state.isDeclared("2") }
    private var showColorTemp: Bool { !state.isDeclared(state.colorTempKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showBrightness {
                HStack(spacing: 8) {
                    Image(systemName: "sun.max")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $brightness, in: 10...1000, onEditingChanged: { editing in
                        isDraggingBrightness = editing
                        if !editing {
                            Task {
                                await store.setDps(device, ["2": Int(brightness.rounded())])
                            }
                        }
                    })
                    .controlSize(.mini)
                    Text("\(Int(brightness.rounded()))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }

            if showColorTemp, let tempKey = state.colorTempKey {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.sun")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $colorTemp, in: 0...1000, onEditingChanged: { editing in
                        isDraggingTemp = editing
                        if !editing {
                            Task {
                                await store.setDps(device, [tempKey: Int(colorTemp.rounded())])
                            }
                        }
                    })
                    .controlSize(.mini)
                    Text("\(Int(colorTemp.rounded()))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
        .onAppear {
            brightness = state.brightness ?? 500
            colorTemp = state.colorTemp ?? 500
        }
        .onChange(of: state.brightness ?? 500) { newValue in
            if !isDraggingBrightness { brightness = newValue }
        }
        .onChange(of: state.colorTemp ?? 500) { newValue in
            if !isDraggingTemp { colorTemp = newValue }
        }
    }
}

struct PlugReadoutView: View {
    let state: DeviceState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(state.wattsText ?? "– W")
                .font(.callout.weight(.semibold))
                .monospacedDigit()

            Spacer()

            if let voltage = state.voltage {
                Text("\(DPSValue.format(voltage)) V")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let current = state.current {
                Text(String(format: "%.2f A", current))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ClimateChipsView: View {
    let state: DeviceState

    var body: some View {
        HStack(spacing: 6) {
            if let temperature = state.temperature {
                chip("🌡 \(DPSValue.format(temperature)) °C")
            }
            if let humidity = state.humidity {
                chip("💧 \(Int(humidity.rounded())) %")
            }
            if state.temperature == nil && state.humidity == nil {
                Text(state.isEmpty ? "Waiting for status…" : "No climate values")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

struct RawPreviewView: View {
    let state: DeviceState
    let kind: DeviceKind

    var body: some View {
        let entries = Array(state.entries(for: kind).prefix(3))
        Text(state.isEmpty
             ? "No status yet"
             : entries.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

// MARK: - Detail

struct DeviceDetailView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device

    private var state: DeviceState { store.state(for: device) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: device.kind.iconName)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 46)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name)
                            .font(.title2.bold())
                        Text("\(device.kind.label) · \(device.category.isEmpty ? "uncategorised" : device.category)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(device.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        Text(device.hasAddress ? device.ip : "No IP")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                HStack(spacing: 10) {
                    if let watts = state.wattsText {
                        Text(watts)
                            .font(.headline.monospacedDigit())
                    }
                    if let temperature = state.temperature {
                        Text("🌡 \(DPSValue.format(temperature)) °C")
                            .font(.headline.monospacedDigit())
                    }
                    if state.power != nil {
                        Text(state.power == true ? "On" : "Off")
                            .font(.headline)
                            .foregroundStyle(state.power == true ? Color.green : Color.secondary)
                    }
                    Spacer()
                }

                Divider()

                HStack {
                    Text("All DPS")
                        .font(.headline)
                    Spacer()
                    if store.isLoadingStatus(device) {
                        ProgressView().controlSize(.small)
                    }
                    Button("Refresh") {
                        Task { await store.loadStatus(for: device, force: true) }
                    }
                    .controlSize(.small)
                }

                if let error = store.statusErrors[device.id] {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                if state.isEmpty && !store.isLoadingStatus(device) {
                    Text("No DPS reported yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(state.entries(for: device.kind)) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(entry.key)
                                    .font(.callout.monospaced())
                                    .frame(width: 44, alignment: .leading)
                                Text(entry.label)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.value)
                                    .font(.callout.monospacedDigit())
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: device.id) {
            await store.loadStatus(for: device)
        }
    }
}
