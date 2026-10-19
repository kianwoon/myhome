// baseline-guard:allow new spec-driven controls source, no prior baseline
import SwiftUI
import MyHomeCore

/// Renders one control per upstream-declared dp. Inferred controls live in
/// RichControlView and are shown only for dps the spec does not declare.
struct SpecControlsView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let state: DeviceState

    var body: some View {
        let controls = state.controlCapabilities
        if controls.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(controls) { capability in
                    CapabilityRow(device: device, state: state, capability: capability)
                }
            }
        }
    }

}

private struct CapabilityRow: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let state: DeviceState
    let capability: Capability

    @State private var numberValue: Double = 0
    @State private var editingNumber = false

    var body: some View {
        switch capability.kind {
        case .boolean:
            Toggle(isOn: Binding(
                get: { state.dps[capability.dpId]?.boolValue ?? false },
                set: { newValue in
                    Task {
                        await store.setDps(
                            device,
                            [capability.dpId: newValue],
                            optimistic: [capability.dpId: .bool(newValue)]
                        )
                    }
                }
            )) {
                Text(capability.displayName)
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

        case .enumeration:
            HStack(spacing: 8) {
                Text(capability.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: {
                        state.dps[capability.dpId]?.stringValue
                            ?? capability.range.first
                            ?? ""
                    },
                    set: { newValue in
                        Task {
                            await store.setDps(
                                device,
                                [capability.dpId: newValue],
                                optimistic: [capability.dpId: .string(newValue)]
                            )
                        }
                    }
                )) {
                    ForEach(capability.range, id: \.self) { value in
                        Text(value.capitalized).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }

        case .integer:
            // General rule: a stepped SwiftUI Slider becomes an AppKit slider
            // with (max-min)/step TICK MARKS, and AppKit rebuilds every tick
            // rect on each layout (NSSliderTickMarks._rebuildTickMarkRectCache).
            // Upstream declares dps like countdown_1 (0-86400s, step 1): a
            // stepped slider there is 86,400 tick rects per card per render —
            // the 100% CPU hang. So: countdown/timer dps are not sliders at
            // all, and any range whose tick count would exceed 100 renders
            // step-free (continuous, zero tick marks).
            if capability.code.lowercased().contains("countdown") {
                EmptyView()
            } else if let lower = capability.minValue, let upper = capability.maxValue {
                let ticks = (upper - lower) / (capability.step ?? 1)
                if ticks > 100 {
                HStack(spacing: 8) {
                    Text(capability.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $numberValue,
                        in: lower...max(lower, upper),
                        step: max(capability.step ?? 1, 0.1),
                        onEditingChanged: { editing in
                            editingNumber = editing
                            if !editing {
                                Task {
                                    await store.setDps(device, [capability.dpId: numberValue])
                                }
                            }
                        }
                    )
                    .controlSize(.mini)
                    Text(numberLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
                .onAppear {
                    numberValue = state.dps[capability.dpId]?.doubleValue ?? lower
                }
                .onChange(of: state.dps[capability.dpId]?.doubleValue ?? lower) { newValue in
                    if !editingNumber {
                        numberValue = newValue
                    }
                }
                } else {
                    // Continuous slider: no step, therefore no tick marks.
                    HStack(spacing: 8) {
                        Text(capability.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $numberValue,
                               in: lower...max(lower, upper)) { editing in
                            editingNumber = editing
                            if !editing {
                                Task { await store.setDps(device, [capability.dpId: numberValue]) }
                            }
                        }
                        .controlSize(.mini)
                        Text(numberLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                    .onAppear {
                        numberValue = state.dps[capability.dpId]?.doubleValue ?? lower
                    }
                }
            }

        default:
            EmptyView()
        }
    }

    private var numberLabel: String {
        let text = DPSValue.format(numberValue)
        if let unit = capability.unit, !unit.isEmpty {
            return "\(text) \(unit)"
        }
        return text
    }
}
