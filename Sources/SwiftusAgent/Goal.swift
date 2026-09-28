import Foundation
import SwiftusCore
import SwiftusFoundation

/// Goal 变更事件类型（规格 S16 §7.1）。
public let kGoalEvent = "goal/changed"

/// 达到轮次上限时的阻塞原因（续行驱动器与默认服务共用）。
public let kGoalRoundLimitReason = "达到轮次上限，等待用户介入"

/// 目标状态。
public enum GoalStatus: String, Sendable, CaseIterable {
    /// 活动，可被续行驱动器推进。
    case active
    /// 暂停，需用户显式 resume。
    case paused
    /// 阻塞，需用户介入。
    case blocked
    /// 完成，终态。
    case completed
    /// 清除，终态。
    case cleared
}

/// 目标修订记录。
public struct GoalRevision: Sendable, Equatable {
    /// 该版文本。
    public let text: String
    /// 修订时间。
    public let revisedAt: Date

    public init(text: String, revisedAt: Date) {
        self.text = text
        self.revisedAt = revisedAt
    }

    public init(jsonValue: JSONValue) {
        let object = jsonValue.objectValue ?? [:]
        text = object["text"]?.stringValue ?? ""
        revisedAt = parseInstant(object["revisedAt"])
    }

    public var jsonValue: JSONValue {
        .object([
            "text": .string(text),
            "revisedAt": .string(instantString(revisedAt)),
        ])
    }
}

/// 一个长期目标（规格 S16 §7.1）。每会话至多一个当前目标。
public struct Goal: Sendable, Equatable {
    /// 目标唯一 ID。
    public let id: String
    /// 目标描述。
    public let text: String
    /// 当前状态。
    public let status: GoalStatus
    /// 已用轮次。
    public let round: Int
    /// 轮次上限。
    public let maxRounds: Int
    /// 创建时间。
    public let createdAt: Date
    /// 最后更新时间。
    public let updatedAt: Date
    /// 修订历史（含初版）。
    public let revisions: [GoalRevision]
    /// 阻塞原因（status == blocked 时非空）。
    public let blockReason: String?

    public init(
        id: String,
        text: String,
        status: GoalStatus,
        round: Int,
        maxRounds: Int,
        createdAt: Date,
        updatedAt: Date,
        revisions: [GoalRevision] = [],
        blockReason: String? = nil
    ) {
        self.id = id
        self.text = text
        self.status = status
        self.round = round
        self.maxRounds = maxRounds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revisions = revisions
        self.blockReason = blockReason
    }

    /// 是否为终态。
    public var isTerminal: Bool {
        status == .completed || status == .cleared
    }

    /// 是否可被续行驱动器推进。
    public var isAdvanceable: Bool {
        status == .active
    }

    /// 返回更新后的副本；blockReason 传 `.some(nil)` 表示清除，传 nil 表示不改。
    public func copyWith(
        text: String? = nil,
        status: GoalStatus? = nil,
        round: Int? = nil,
        updatedAt: Date? = nil,
        revisions: [GoalRevision]? = nil,
        blockReason: String?? = nil
    ) -> Goal {
        Goal(
            id: id,
            text: text ?? self.text,
            status: status ?? self.status,
            round: round ?? self.round,
            maxRounds: maxRounds,
            createdAt: createdAt,
            updatedAt: updatedAt ?? self.updatedAt,
            revisions: revisions ?? self.revisions,
            blockReason: blockReason ?? self.blockReason
        )
    }

    public init(jsonValue: JSONValue) {
        let object = jsonValue.objectValue ?? [:]
        id = object["id"]?.stringValue ?? ""
        text = object["text"]?.stringValue ?? ""
        status = GoalStatus(rawValue: object["status"]?.stringValue ?? "") ?? .active
        round = object["round"]?.intValue ?? 0
        maxRounds = object["maxRounds"]?.intValue ?? 256
        createdAt = parseInstant(object["createdAt"])
        updatedAt = parseInstant(object["updatedAt"])
        revisions = (object["revisions"]?.arrayValue ?? []).map(GoalRevision.init(jsonValue:))
        blockReason = object["blockReason"]?.stringValue
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "text": .string(text),
            "status": .string(status.rawValue),
            "round": .int(Int64(round)),
            "maxRounds": .int(Int64(maxRounds)),
            "createdAt": .string(instantString(createdAt)),
            "updatedAt": .string(instantString(updatedAt)),
            "revisions": .array(revisions.map(\.jsonValue)),
        ]
        if let blockReason {
            object["blockReason"] = .string(blockReason)
        }
        return .object(object)
    }
}

/// Goal 相关错误（code: already_exists / invalid_status / no_goal / cancelled）。
public struct GoalException: Error, Equatable {
    /// 稳定的机器可读错误码。
    public let code: String
    /// 面向用户/模型的可读消息。
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

extension GoalException: CustomStringConvertible {
    public var description: String {
        "GoalException(\(code)): \(message)"
    }
}

/// 折叠会话自身后缀里最后一个 goal/changed 事件，还原目标状态；
/// 无事件或最后状态为 cleared 时返回 nil（规格 S16 §7.1）。
@ContextTreeActor
public func restoreGoalState(_ session: Session) -> Goal? {
    for event in session.ownEvents.reversed() where event.type == kGoalEvent {
        guard let data = event.data, case .object = data else { continue }
        if data["status"]?.stringValue != "cleared" {
            return Goal(jsonValue: data)
        }
        return nil
    }
    return nil
}

/// ISO8601 时刻解析（UTC 小数秒形态，宽容失败退回当前时刻）。
func parseInstant(_ value: JSONValue?) -> Date {
    guard let text = value?.stringValue,
          let parsed = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) else {
        return Date()
    }
    return parsed
}

/// ISO8601 时刻序列化。
func instantString(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}
