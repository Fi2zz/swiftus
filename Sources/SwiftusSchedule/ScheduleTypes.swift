import Foundation
import SwiftusCore

/// 持久提醒变更事件的类型名（规格 S8 §1.1）。
public let kScheduleChangeEvent = "schedule/change"

/// 本包实现的持久协议版本。
public let kScheduleChangeVersion = 1

/// 固定间隔提醒的最小间隔（秒）。
public let kMinEveryIntervalSeconds = 300

/// 交付边界常量：提醒只在原会话内交付。
public let kScheduleDeliveryMode = "session-local"

/// 单个定时器分段的上限（毫秒）；每次唤醒都会重新采样墙钟（规格 S8 §10.2）。
public let kMaxTimerSegmentMilliseconds: Int64 = 2_147_483_647

/// 提醒规则种类（规格 S8 §1.2）。
public enum ScheduleKind: String, Sendable {
    /// 延迟指定秒数后触发的一次性提醒。
    case after
    /// 指定绝对时刻的一次性提醒。
    case at
    /// 按固定间隔重复的提醒。
    case every

    /// 持久 JSON 中的判别值。
    public var wire: String {
        rawValue
    }
}

/// 提醒相对当前墙钟的交付时机（规格 S8 §1.3）。
public enum ScheduleState: String, Sendable {
    /// 目标时刻仍在未来。
    case scheduled
    /// 目标时刻已到、等待交付。
    case overdue

    /// 工具结果中的判别值。
    public var wire: String {
        rawValue
    }
}

/// 一条持久提醒记录（规格 S8 §1.2）。
public struct ScheduleRecord: Sendable, Equatable {
    /// 会话内唯一、永不复用的标识。
    public let id: String
    /// 规则种类，决定 afterSeconds / everySeconds 哪一个有值。
    public let kind: ScheduleKind
    /// 创建时提供的提醒内容（已去首尾空白）。
    public let prompt: String
    /// 四位年份 RFC 3339 UTC 目标时刻；every 下为最早尚未派发的锚点对齐发生时点。
    public let scheduledAt: Date
    /// 创建时接受的延迟秒数，仅 after 有值。
    public let afterSeconds: Int?
    /// 创建时接受的固定间隔秒数，仅 every 有值。
    public let everySeconds: Int?

    public init(
        id: String,
        kind: ScheduleKind,
        prompt: String,
        scheduledAt: Date,
        afterSeconds: Int? = nil,
        everySeconds: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
        self.scheduledAt = scheduledAt
        self.afterSeconds = afterSeconds
        self.everySeconds = everySeconds
    }

    /// 序列化为持久 JSON（有值才落键，规格 S8 §1.2）。
    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "kind": .string(kind.wire),
            "prompt": .string(prompt),
        ]
        if let afterSeconds {
            object["afterSeconds"] = .int(Int64(afterSeconds))
        }
        if let everySeconds {
            object["everySeconds"] = .int(Int64(everySeconds))
        }
        object["scheduledAt"] = .string(formatUtcInstant(scheduledAt))
        return .object(object)
    }

    /// 派生同一记录的副本，仅改目标时刻（固定间隔派发后推进用）。
    public func withScheduledAt(_ next: Date) -> ScheduleRecord {
        ScheduleRecord(
            id: id,
            kind: kind,
            prompt: prompt,
            scheduledAt: next,
            afterSeconds: afterSeconds,
            everySeconds: everySeconds
        )
    }
}

/// 一条活动提醒的模型可见视图（规格 S8 §1.3）。
public struct ScheduleView: Sendable, Equatable {
    /// 被呈现的持久记录。
    public let record: ScheduleRecord
    /// 相对当前墙钟的时机状态。
    public let state: ScheduleState

    public init(record: ScheduleRecord, state: ScheduleState) {
        self.record = record
        self.state = state
    }

    /// 序列化为工具结果：记录字段在前，状态与交付模式在后。
    public var jsonValue: JSONValue {
        var object = record.jsonValue.objectValue ?? [:]
        object["state"] = .string(state.wire)
        object["deliveryMode"] = .string(kScheduleDeliveryMode)
        return .object(object)
    }
}

/// 一条已到期的固定间隔提醒，以及被选中的最新发生时点。
public struct ScheduleDue: Sendable, Equatable {
    /// 仍然活动的固定间隔记录。
    public let record: ScheduleRecord
    /// 该记录在决策时点最新一个锚点对齐的到期时点。
    public let occurrenceAt: Date

    public init(record: ScheduleRecord, occurrenceAt: Date) {
        self.record = record
        self.occurrenceAt = occurrenceAt
    }
}

/// 一次回放的结果（规格 S8 §1.3）：活动记录按创建顺序，seenIds 保留所有用过的标识。
public struct ScheduleFold: Sendable {
    /// 仍然活动的记录，保持创建顺序。
    public let active: [ScheduleRecord]
    /// 本会话后缀里出现过的全部 id（含已删除、已派发的）。
    public let seenIds: [String]

    public init(active: [ScheduleRecord], seenIds: [String]) {
        self.active = active
        self.seenIds = seenIds
    }

    /// 按 id 找一条活动记录；不存在返回 nil。
    public func find(_ id: String) -> ScheduleRecord? {
        active.first { $0.id == id }
    }
}

/// `schedule_delete` 的结果：删除成功，或目标不存在（不改动任何状态）。
public struct ScheduleDeleteResult: Sendable, Equatable {
    /// 被请求删除的标识。
    public let id: String
    /// 是否确实删掉了一条活动记录。
    public let deleted: Bool

    public init(id: String, deleted: Bool) {
        self.id = id
        self.deleted = deleted
    }

    /// 序列化为工具结果；未删除时附 schedule_not_found（规格 S8 §1.3）。
    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "deleted": .bool(deleted),
        ]
        if !deleted {
            object["code"] = .string(ScheduleErrorCode.notFound.rawValue)
        }
        return .object(object)
    }
}
