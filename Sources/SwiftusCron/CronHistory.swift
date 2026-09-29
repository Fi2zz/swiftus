import Foundation
import SwiftusCore

/// 一条运行记录（历史 JSONL 的一行，规格 S9 §7）。
public struct CronRunRecord: Sendable, Equatable {
    public var id: String
    public let seq: Int
    public let taskId: String
    public let prompt: String
    public let sessionId: String?
    /// 排期的触发时刻。
    public let scheduledFor: Date
    /// 实际交付时刻。
    public let firedAt: Date
    public var status: CronRunStatus
    public var excerpt: String?
    public let endReason: String?
    public let startedAt: Date?
    public var completedAt: Date?

    public init(
        id: String,
        seq: Int,
        taskId: String,
        prompt: String,
        sessionId: String?,
        scheduledFor: Date,
        firedAt: Date,
        status: CronRunStatus,
        excerpt: String? = nil,
        endReason: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.seq = seq
        self.taskId = taskId
        self.prompt = prompt
        self.sessionId = sessionId
        self.scheduledFor = scheduledFor
        self.firedAt = firedAt
        self.status = status
        self.excerpt = excerpt
        self.endReason = endReason
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// 序列化为历史 JSONL 的一行：创建时必有的字段始终写出，其余可空字段为
    /// 空时**省略键**（`sessionId` 除外，它恒为 `null` 或值）。
    public var json: [String: JSONValue] {
        var raw: [String: JSONValue] = [
            "id": .string(id),
            "seq": .int(Int64(seq)),
            "taskId": .string(taskId),
            "prompt": .string(prompt),
            "sessionId": sessionId.map { .string($0) } ?? .null,
            "scheduledFor": CronInstant.format(scheduledFor),
            "firedAt": CronInstant.format(firedAt),
            "status": .string(status.rawValue),
        ]
        if let excerpt { raw["excerpt"] = .string(excerpt) }
        if let endReason { raw["endReason"] = .string(endReason) }
        if let startedAt { raw["startedAt"] = CronInstant.format(startedAt) }
        if let completedAt { raw["completedAt"] = CronInstant.format(completedAt) }
        return raw
    }

    /// 宽容解码历史 JSONL 的一行；缺 id 或 id 为空串返回 nil（调用方跳过错行）。
    ///
    /// 宽容的含义：其余字段缺失时取中性值（序号 0、任务与提示空串、时刻取纪元、
    /// 状态取 `delivered`），这样 dsh-cron 时代写下的行也能读。
    public static func decode(_ raw: JSONValue) -> CronRunRecord? {
        guard let object = raw.objectValue,
              let id = object["id"]?.stringValue, !id.isEmpty else {
            return nil
        }
        return CronRunRecord(
            id: id,
            seq: cronInt(object["seq"]) ?? 0,
            taskId: object["taskId"]?.stringValue ?? "",
            prompt: object["prompt"]?.stringValue ?? "",
            sessionId: object["sessionId"]?.stringValue,
            scheduledFor: cronInstant(object["scheduledFor"]) ?? Date(timeIntervalSince1970: 0),
            firedAt: cronInstant(object["firedAt"]) ?? Date(timeIntervalSince1970: 0),
            status: object["status"].flatMap { $0.stringValue }.flatMap { CronRunStatus(rawValue: $0) } ?? .delivered,
            excerpt: object["excerpt"]?.stringValue,
            endReason: object["endReason"]?.stringValue,
            startedAt: cronInstant(object["startedAt"]),
            completedAt: cronInstant(object["completedAt"])
        )
    }
}

/// 宽容解码整数：整数值取整，其余（含小数、字符串、null）返回 nil。
func cronInt(_ value: JSONValue?) -> Int? {
    switch value {
    case .some(.int(let raw)): return Int(exactly: raw)
    case .some(.double(let raw)): return raw == raw.rounded() ? Int(exactly: raw.rounded()) : nil
    default: return nil
    }
}

/// 宽容解码瞬时：ISO 串或整数毫秒（dsh-cron 兼容），其余返回 nil。
func cronInstant(_ value: JSONValue?) -> Date? {
    if case .some(.string(let text)) = value { return CronInstant.parse(text) }
    if let millis = cronInt(value) { return Date(timeIntervalSince1970: Double(millis) / 1000) }
    return nil
}

/// 预分配的记录标识（交付端口以 id 关联 `finish`）。
public struct CronRecordRef: Sendable, Equatable {
    public let id: String
    public let seq: Int

    public init(id: String, seq: Int) {
        self.id = id
        self.seq = seq
    }
}

/// 系统通知端口（只保留抽象，平台实现不在本移植范围，规格 S9 §11）。
@ContextTreeActor
public protocol CronNotifier: AnyObject, Sendable {
    func notify(title: String, body: String, taskId: String?)
}
