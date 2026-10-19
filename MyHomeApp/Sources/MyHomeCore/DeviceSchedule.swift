// baseline-guard:allow new schedule model source, no prior baseline
import Foundation

/// One flattened Tuya timer group as returned by the bridge `schedules` cmd.
public struct DeviceSchedule: Identifiable, Decodable, Hashable {
    public let groupId: String
    public let category: String
    public let aliasName: String
    public let loops: String
    public let time: String
    public let code: String
    public let value: Bool
    public let action: String
    public let status: Int
    public let ours: Bool

    public static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    public var id: String { "\(category)/\(groupId)" }
    public var isEnabled: Bool { status != 0 }
    public var actionLabel: String { action.isEmpty ? (value ? "ON" : "OFF") : action }

    /// Enabled day indexes, Monday-first.
    public var dayIndexes: [Int] {
        loops.enumerated().compactMap { index, character in
            index < 7 && character == "1" ? index : nil
        }
    }

    /// "Open · every day 08:30" when the user left the name blank.
    public var generatedName: String {
        let days: String
        if dayIndexes.count == 7 {
            days = "every day"
        } else if dayIndexes.isEmpty {
            days = "once"
        } else {
            days = dayIndexes.map { Self.dayNames[$0] }.joined(separator: ",")
        }
        return "\(actionLabel) · \(days) \(time)"
    }

    public var displayName: String {
        aliasName.isEmpty ? generatedName : aliasName
    }

    private enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case category, aliasName = "alias_name", loops, time, code, value, action, status, ours
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groupId = (try? container.decode(String.self, forKey: .groupId)) ?? ""
        category = (try? container.decode(String.self, forKey: .category)) ?? ""
        aliasName = (try? container.decode(String.self, forKey: .aliasName)) ?? ""
        loops = (try? container.decode(String.self, forKey: .loops)) ?? ""
        time = (try? container.decode(String.self, forKey: .time)) ?? ""
        code = (try? container.decode(String.self, forKey: .code)) ?? ""
        if let boolValue = try? container.decode(Bool.self, forKey: .value) {
            value = boolValue
        } else if let intValue = try? container.decode(Int.self, forKey: .value) {
            value = intValue != 0
        } else {
            value = false
        }
        action = (try? container.decode(String.self, forKey: .action))
            ?? (value ? "ON" : "OFF")
        status = (try? container.decode(Int.self, forKey: .status)) ?? 0
        ours = (try? container.decode(Bool.self, forKey: .ours)) ?? false
    }
}
