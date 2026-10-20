// baseline-guard:allow new schedule UI source, no prior baseline
import SwiftUI
import MyHomeCore

/// Cloud-owned timer groups for the selected device. Loaded on appear and
/// reloaded after every add/toggle/delete; the periodic status poll does not
/// touch this list because schedules are slow-moving cloud data.
/// What the shared add/edit sheet should present.
private enum ScheduleSheet: Identifiable {
    case add
    case edit(DeviceSchedule)

    var id: String {
        switch self {
        case .add:
            return "add"
        case .edit(let schedule):
            return schedule.id
        }
    }
}

struct ScheduleSection: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device

    @State private var sheet: ScheduleSheet?
    @State private var pendingDelete: DeviceSchedule?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Schedule")
                    .font(.headline)
                Spacer()
                if store.schedulesLoading {
                    ProgressView().controlSize(.small)
                }
                Button("+ Add Schedule") { sheet = .add }
                    .controlSize(.small)
            }

            if let error = store.schedulesError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if store.schedules.isEmpty && !store.schedulesLoading {
                Text("No schedules for this device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(store.schedules) { schedule in
                ScheduleRow(
                    schedule: schedule,
                    device: device,
                    onEdit: { sheet = .edit(schedule) },
                    onDelete: { pendingDelete = schedule }
                )
            }
        }
        .task(id: device.id) {
            await store.loadSchedules(for: device)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add:
                AddScheduleSheet(device: device, schedule: nil)
            case .edit(let schedule):
                AddScheduleSheet(device: device, schedule: schedule)
            }
        }
        .alert(
            "Delete schedule?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { presented in if !presented { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { schedule in
            Button("Delete", role: .destructive) {
                pendingDelete = nil
                Task { await store.deleteSchedule(schedule, for: device) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { schedule in
            Text(schedule.displayName)
        }
    }
}

private struct ScheduleRow: View {
    @EnvironmentObject private var store: DeviceStore
    let schedule: DeviceSchedule
    let device: Device
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { schedule.isEnabled },
            set: { enabled in
                Task { await store.setScheduleEnabled(schedule, for: device, enabled: enabled) }
            }
        )
    }

    /// Enum actions keep their semantic color: open/continue/on run (green),
    /// close/off are closed (secondary); unknown enum labels use accent.
    private var actionColor: Color {
        switch schedule.actionLabel.lowercased() {
        case "open", "continue", "on":
            return .green
        case "close", "off":
            return .secondary
        default:
            return .accentColor
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(schedule.dayIndexes, id: \.self) { index in
                        Text(DeviceSchedule.dayNames[index])
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    }
                    if schedule.dayIndexes.isEmpty {
                        Text("Once")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(schedule.time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !schedule.ours {
                        Text("Phone")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)

            Text(schedule.actionLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(actionColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(
                    actionColor.opacity(0.12)
                ))

            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit schedule")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete schedule")
        }
        .padding(.vertical, 2)
    }
}

private struct AddScheduleSheet: View {
    @EnvironmentObject private var store: DeviceStore
    @Environment(\.dismiss) private var dismiss
    let device: Device
    let schedule: DeviceSchedule?

    @State private var name: String
    @State private var time: Date
    @State private var days: [Bool]
    @State private var isOn: Bool
    @State private var saving = false

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(device: Device, schedule: DeviceSchedule?) {
        self.device = device
        self.schedule = schedule
        _name = State(initialValue: schedule?.aliasName ?? "")
        let initialTime = schedule.flatMap { Self.formatter.date(from: $0.time) } ?? Date()
        _time = State(initialValue: initialTime)
        var initialDays = Array(repeating: false, count: 7)
        if let loops = schedule?.loops {
            for (index, character) in loops.prefix(7).enumerated() where character == "1" {
                initialDays[index] = true
            }
        } else {
            initialDays = Array(repeating: true, count: 7)
        }
        _days = State(initialValue: initialDays)
        _isOn = State(initialValue: schedule?.value ?? true)
    }

    private var isEditing: Bool { schedule != nil }

    private var timeText: String { Self.formatter.string(from: time) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edit Schedule" : "Add Schedule")
                .font(.headline)

            TextField("Name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Text("Time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DatePicker(
                    "Time",
                    selection: $time,
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .datePickerStyle(.field)
                .environment(\.locale, Locale(identifier: "en_GB"))
                Spacer()
                Text("24h")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { index in
                        Button {
                            days[index].toggle()
                        } label: {
                            Text(DeviceSchedule.dayNames[index])
                                .font(.caption2.weight(.medium))
                                .frame(width: 38, height: 30)
                                .background(Capsule().fill(
                                    days[index] ? Color.accentColor : Color.secondary.opacity(0.15)
                                ))
                                .foregroundStyle(days[index] ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 10) {
                    Button("Every day") { days = Array(repeating: true, count: 7) }
                    Button("Weekdays") {
                        days = [true, true, true, true, true, false, false]
                    }
                    Button("Weekend") {
                        days = [false, false, false, false, false, true, true]
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }

            HStack(spacing: 10) {
                Text("Action")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Action", selection: $isOn) {
                    Text("ON").tag(true)
                    Text("OFF").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 130)
                Spacer()
            }

            HStack {
                if let error = store.schedulesError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : (isEditing ? "Save" : "Add"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submit() {
        guard !saving else { return }
        saving = true
        Task {
            let ok: Bool
            if let schedule {
                ok = await store.editSchedule(
                    schedule,
                    for: device,
                    name: name,
                    days: days,
                    time: timeText,
                    on: isOn
                )
            } else {
                ok = await store.addSchedule(
                    for: device,
                    name: name,
                    days: days,
                    time: timeText,
                    on: isOn
                )
            }
            saving = false
            if ok { dismiss() }
        }
    }
}
