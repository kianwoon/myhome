// baseline-guard:allow rewrite of existing store for live polling and confirmed writes
import Foundation
import SwiftUI

/// Minimal seam over the stdio bridge so write paths can be unit-tested with a
/// canned `set` reply instead of real hardware.
public protocol BridgeSending: Sendable {
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any]
}

extension BridgeClient: BridgeSending {}

public extension BridgeSending {
    /// Matches BridgeClient's default per-request timeout.
    func request(_ payload: [String: Any]) async throws -> [String: Any] {
        try await request(payload, timeout: 6)
    }
}

@MainActor
public final class DeviceStore: ObservableObject {
    /// General rule: device status is LIVE REMOTE data — it must be
    /// (a) re-polled periodically, (b) re-read after every write using the set
    /// reply's confirmed dps, and (c) never shown as authoritative without a
    /// fetch. One instance is the fan card: without polling it shows a stale
    /// speed after the wall switch or Tuya app changes it.
    ///
    /// One full cycle every 10s, round-robin, with a small pause between
    /// requests because the bridge is serial.
    public static let statusPollInterval: TimeInterval = 10
    public static let statusPollPacing: TimeInterval = 0.15

    @Published public private(set) var devices: [Device] = []
    @Published public private(set) var isOn: [String: Bool] = [:]
    @Published public private(set) var dpsById: [String: [String: DPSValue]] = [:]
    @Published public private(set) var statusLoading: Set<String> = []
    @Published public private(set) var statusErrors: [String: String] = [:]
    @Published public private(set) var errorText: String?
    @Published public private(set) var isWorking = false

    private let bridge: any BridgeSending
    private var loadedStatus: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var pollObservers = 0

    public init(bridge: any BridgeSending = BridgeClient.shared) {
        self.bridge = bridge
    }

    // MARK: - Derived state

    public var onlineCount: Int {
        devices.filter { $0.online && $0.hasAddress }.count
    }

    public var onCount: Int {
        devices.filter { isOn[$0.id] == true }.count
    }

    public var headerText: String {
        "⚡ \(onCount) on · 🟢 \(onlineCount)/\(devices.count) online"
    }

    public func state(for device: Device) -> DeviceState {
        DeviceState(dps: dpsById[device.id] ?? [:])
    }

    /// nil until a fetch (or confirmed write) has reported dps 1.
    public func power(for device: Device) -> Bool? {
        isOn[device.id] ?? dpsById[device.id]?["1"]?.boolValue
    }

    public func dps(for device: Device) -> [String: DPSValue] {
        dpsById[device.id] ?? [:]
    }

    public func isLoadingStatus(_ device: Device) -> Bool {
        statusLoading.contains(device.id)
    }

    // MARK: - List / rescan

    public func refresh() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let reply = try await bridge.request(["cmd": "list"])
            guard reply["ok"] as? Bool == true else {
                errorText = reply["error"] as? String ?? "Could not list devices."
                return
            }
            guard let rawDevices = reply["devices"] else {
                errorText = "Bridge returned no devices."
                return
            }
            let data = try JSONSerialization.data(withJSONObject: rawDevices)
            let decoded = try JSONDecoder().decode([Device].self, from: data)
            devices = decoded
            // Deliberately no isOn default: unknown power stays indeterminate
            // until status arrives.
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    public func rescan() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let reply = try await bridge.request(["cmd": "rescan"], timeout: 30)
            guard reply["ok"] as? Bool == true else {
                errorText = reply["error"] as? String ?? "Scan failed."
                return
            }
            errorText = nil
            loadedStatus.removeAll()
            dpsById.removeAll()
            statusErrors.removeAll()
        } catch {
            errorText = error.localizedDescription
        }
        await refresh()
    }

    // MARK: - Polling

    /// Reference-counted so the menu extra and the main window can each keep
    /// polling alive independently.
    public func startPolling() {
        pollObservers += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self = self else { return }
            await self.pollLoop()
        }
    }

    public func stopPolling() {
        pollObservers = max(0, pollObservers - 1)
        guard pollObservers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollCycle()
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.statusPollInterval * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    /// Round-robin over online devices only; skip anything already in flight.
    private func pollCycle() async {
        for device in devices where device.hasAddress {
            if Task.isCancelled { return }
            if statusLoading.contains(device.id) { continue }
            await loadStatus(for: device, force: true)
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.statusPollPacing * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    // MARK: - Status

    /// Fetches DPS for one device. Non-forced calls are cached until a rescan
    /// or poll forces a re-read; concurrent calls for the same id de-duplicate.
    public func loadStatus(for device: Device, force: Bool = false) async {
        guard device.hasAddress else { return }
        guard !statusLoading.contains(device.id) else { return }
        if !force && loadedStatus.contains(device.id) { return }

        statusLoading.insert(device.id)
        defer { statusLoading.remove(device.id) }

        do {
            let reply = try await bridge.request(["cmd": "status", "id": device.id])
            guard reply["ok"] as? Bool == true else {
                statusErrors[device.id] = reply["error"] as? String ?? "Status failed."
                return
            }
            guard let raw = reply["dps"] else {
                statusErrors[device.id] = "Device returned no dps."
                return
            }
            try applyStatus(device.id, raw: raw)
        } catch {
            statusErrors[device.id] = error.localizedDescription
        }
    }

    public func loadAllStatuses() async {
        for device in devices where device.hasAddress {
            await loadStatus(for: device)
        }
    }

    private func applyStatus(_ id: String, raw: Any) throws {
        let decoded = try Self.decodeDps(raw)
        dpsById[id] = decoded
        statusErrors[id] = nil
        loadedStatus.insert(id)
        if let power = decoded["1"]?.boolValue {
            isOn[id] = power
        }
    }

    public static func decodeDps(_ raw: Any) throws -> [String: DPSValue] {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode([String: DPSValue].self, from: data)
    }

    // MARK: - Writes

    /// Optimistic toggle: flips instantly, then the confirmed reply wins; only
    /// a rejected set reverts to the previous state.
    public func toggle(_ device: Device, to newValue: Bool) async {
        guard device.hasAddress else { return }
        let previous = power(for: device) ?? false
        let previousDps = dpsById[device.id]

        isOn[device.id] = newValue
        dpsById[device.id, default: [:]][ "1"] = .bool(newValue)

        do {
            let reply = try await bridge.request([
                "cmd": "set",
                "id": device.id,
                "dps": ["1": newValue]
            ])
            if reply["ok"] as? Bool == true {
                try applyConfirmedReply(device.id, reply: reply)
                errorText = nil
            } else {
                revert(device: device, isOn: previous, dps: previousDps)
                errorText = reply["error"] as? String ?? "Set failed."
            }
        } catch {
            revert(device: device, isOn: previous, dps: previousDps)
            errorText = error.localizedDescription
        }
    }

    /// Sends an arbitrary DPS patch, optionally painting the expected values
    /// first. On success the reply's confirmed dps is applied immediately; the
    /// device wins over the optimistic value. On failure the previous map is
    /// restored.
    @discardableResult
    public func setDps(
        _ device: Device,
        _ values: [String: Any],
        optimistic: [String: DPSValue] = [:]
    ) async -> Bool {
        guard device.hasAddress else { return false }
        let previousDps = dpsById[device.id]
        let previousOn = isOn[device.id]

        if !optimistic.isEmpty {
            var merged = dpsById[device.id] ?? [:]
            for (key, value) in optimistic {
                merged[key] = value
            }
            dpsById[device.id] = merged
            if let power = merged["1"]?.boolValue {
                isOn[device.id] = power
            }
        }

        do {
            let reply = try await bridge.request([
                "cmd": "set",
                "id": device.id,
                "dps": values
            ])
            if reply["ok"] as? Bool == true {
                try applyConfirmedReply(device.id, reply: reply)
                errorText = nil
                return true
            }
            dpsById[device.id] = previousDps
            isOn[device.id] = previousOn
            errorText = reply["error"] as? String ?? "Set failed."
            return false
        } catch {
            dpsById[device.id] = previousDps
            isOn[device.id] = previousOn
            errorText = error.localizedDescription
            return false
        }
    }

    /// Applies the dps the bridge confirmed from the device after a set. If the
    /// reply carries no dps the optimistic value is left in place.
    private func applyConfirmedReply(_ id: String, reply: [String: Any]) throws {
        guard let raw = reply["dps"] else { return }
        try applyStatus(id, raw: raw)
    }

    private func revert(device: Device, isOn previousOn: Bool, dps previousDps: [String: DPSValue]?) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            isOn[device.id] = previousOn
            dpsById[device.id] = previousDps
        }
    }
}
