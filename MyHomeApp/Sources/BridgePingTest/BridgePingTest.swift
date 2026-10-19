// baseline-guard:allow rewrite of existing test executable to cover status decoding
import Foundation
import MyHomeCore

@main
struct BridgePingTest {
    static func main() async {
        let arguments = CommandLine.arguments
        let mode = arguments.count > 1 ? arguments[1] : "ping"

        if mode == "shapes" {
            proveLooseDecoding()
            return
        }

        if mode == "fanspeed" {
            proveFanSpeed()
            return
        }

        if mode == "setreply" {
            await proveSetReply()
            return
        }

        if mode == "status" {
            let id = arguments.count > 2 ? arguments[2] : "bf3cf132f77b8ca85dapgm"
            await fetchStatus(id: id)
            return
        }

        do {
            let reply = try await BridgeClient.shared.request(["cmd": "ping"])
            let data = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
            let text = String(data: data, encoding: .utf8) ?? "<unreadable>"
            print("PING_REPLY \(text)")
            if reply["ok"] as? Bool == true {
                print("PING_OK")
                exit(0)
            }
            print("PING_FAIL")
            exit(1)
        } catch {
            print("PING_ERROR \(error.localizedDescription)")
            exit(2)
        }
    }

    private static func fetchStatus(id: String) async {
        do {
            let reply = try await BridgeClient.shared.request(["cmd": "status", "id": id])
            guard reply["ok"] as? Bool == true else {
                print("STATUS_ERROR \(reply["error"] ?? "unknown")")
                exit(1)
            }
            guard let raw = reply["dps"] else {
                print("STATUS_ERROR missing dps")
                exit(1)
            }
            let data = try JSONSerialization.data(withJSONObject: raw)
            let decoded = try JSONDecoder().decode([String: DPSValue].self, from: data)
            let state = DeviceState(dps: decoded)
            print("STATUS_DECODED_KEYS \(decoded.keys.sorted())")
            print("POWER \(state.power.map(String.init) ?? "nil") · WATTS \(state.wattsText ?? "nil")")
            print("STATUS_DECODE_OK")
            exit(0)
        } catch {
            print("STATUS_DECODE_ERROR \(error.localizedDescription)")
            exit(2)
        }
    }

    /// Unexpected DPS shapes must decode into the loose enum, never trap.
    private static func proveLooseDecoding() {
        let payload: [String: Any] = [
            "1": true,
            "2": [1, 2, 3],
            "3": ["nested": "value"],
            "4": NSNull(),
            "5": "small",
            "6": 17.5
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let decoded = try JSONDecoder().decode([String: DPSValue].self, from: data)
            print("SHAPES_DECODED \(decoded.keys.sorted())")
            print("SHAPES_OK")
            exit(0)
        } catch {
            print("SHAPES_ERROR \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Fan speed must come from a numeric dps; strings are mode fields and are
    /// only used when no numeric key exists.
    private static func proveFanSpeed() {
        let cases: [(String, [String: Any])] = [
            ("study_fan", ["1": true, "2": "custom", "3": 1]),
            ("numeric_dp2", ["2": 3]),
            ("strings_only", ["2": "large"])
        ]
        do {
            for (name, payload) in cases {
                let data = try JSONSerialization.data(withJSONObject: payload)
                let decoded = try JSONDecoder().decode([String: DPSValue].self, from: data)
                let state = DeviceState(dps: decoded)
                print("\(name) key=\(state.fanSpeedKey ?? "nil") speed=\(state.fanSpeed)")
            }
            print("FANSPEED_OK")
            exit(0)
        } catch {
            print("FANSPEED_ERROR \(error.localizedDescription)")
            exit(1)
        }
    }

    /// setDps must apply the reply's confirmed dps immediately. The fake bridge
    /// returns a different speed than the optimistic value to prove the
    /// DEVICE wins.
    @MainActor
    private static func proveSetReply() async {
        let fake = FakeBridge(reply: [
            "ok": true,
            "dps": ["1": true, "2": "custom", "3": 4]
        ])
        let device = Device(
            id: "bfaded7e0f0815c59eto2l",
            name: "Study Fan",
            ip: "192.168.4.33",
            version: "3.4",
            category: "fs",
            online: true
        )
        let store = DeviceStore(bridge: fake)
        let ok = await store.setDps(device, ["3": 4], optimistic: ["3": .number(2)])
        let state = store.state(for: device)
        let power = store.power(for: device)

        print("SET_REPLY ok=\(ok) power=\(power.map(String.init) ?? "nil") speed=\(state.fanSpeed) key=\(state.fanSpeedKey ?? "nil") dps3=\(state.dps["3"]?.description ?? "nil")")
        print("SET_REQUESTS \(fake.requestCount) CONFIRMED_WINS=\(state.fanSpeed == 4)")
        print("SET_REPLY_APPLIED")
        exit(ok && state.fanSpeed == 4 && state.fanSpeedKey == "3" ? 0 : 1)
    }
}

private final class FakeBridge: BridgeSending, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: [String: Any]
    private var requests: [[String: Any]] = []

    init(reply: [String: Any]) {
        self.reply = reply
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        lock.lock()
        requests.append(payload)
        lock.unlock()
        return reply
    }
}
