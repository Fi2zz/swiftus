import Foundation
import SwiftusCore

/// 消息事件类型常量（规格 S3 §2）。事件类型是开放词汇，其余领域（如 compaction）各自登记。
public enum SessionEventKind {
    /// 用户消息事件类型。
    public static let userMessage = "user/message"
    /// 助手消息事件类型（可携带 `data.toolCalls` 数组，压缩切点安全以此计数，见 S7 §5）。
    public static let assistantMessage = "assistant/message"
    /// 工具结果事件类型。
    public static let toolResult = "tool/result"
}

/// 事件 id 生成器（规格 S3 §1.1）：`evt-<微秒级 Unix 时间戳>-<进程内单调序号>`。
@ContextTreeActor
public enum SessionEventIds {
    private static var sequence: UInt64 = 0

    /// 铸一个进程内单调、跨会话唯一的事件 id。
    public static func next() -> String {
        defer { sequence += 1 }
        let micros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        return "evt-\(micros)-\(sequence)"
    }
}

/// 会话日志中的一条事件（规格 S3 §1）。值类型；`seq` 由所属会话追加时分配，
/// `sessionId` 由追加方补齐。
public struct SessionEvent: Sendable, Equatable {
    /// 日志内的稳定位置（0 起单调递增）。
    public var seq: Int
    /// 事件类型（开放词汇）。
    public var type: String
    /// 事件发生时间。
    public var time: Date
    /// 可 JSON 序列化的负载。
    public var data: JSONValue?
    /// 事件唯一标识；旧数据可能为 nil。
    public var id: String?
    /// 归属会话 id。
    public var sessionId: String?
    /// 触发本事件的父事件 id（因果追踪）。
    public var parentEventId: String?

    public init(
        seq: Int,
        type: String,
        time: Date,
        data: JSONValue? = nil,
        id: String? = nil,
        sessionId: String? = nil,
        parentEventId: String? = nil
    ) {
        self.seq = seq
        self.type = type
        self.time = time
        self.data = data
        self.id = id
        self.sessionId = sessionId
        self.parentEventId = parentEventId
    }

    /// 序列化为 JSONValue（规格 S3 §4.1）：负载递归脱敏，nil 字段不输出。
    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "seq": .int(Int64(seq)),
            "type": .string(type),
            "time": .string(time.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))),
        ]
        if let data {
            object["data"] = Redaction.redactSecrets(data)
        }
        if let id {
            object["id"] = .string(id)
        }
        if let sessionId {
            object["sessionId"] = .string(sessionId)
        }
        if let parentEventId {
            object["parentEventId"] = .string(parentEventId)
        }
        return .object(object)
    }

    /// 从 JSONValue 宽容解析（规格 S3 §4.2）：seq 缺省 0、type 缺省空串、
    /// time 解析失败退回当前时刻（非确定点，语义比对不以 time 为准）。
    public init(jsonValue: JSONValue) {
        let object = jsonValue.objectValue ?? [:]
        seq = object["seq"]?.intValue ?? 0
        type = object["type"]?.stringValue ?? ""
        data = object["data"]
        id = object["id"]?.stringValue
        sessionId = object["sessionId"]?.stringValue
        parentEventId = object["parentEventId"]?.stringValue
        if let text = object["time"]?.stringValue, let parsed = Self.parseTime(text) {
            time = parsed
        } else {
            time = Date()
        }
    }

    /// 宽容解析 ISO8601：先尝试带小数秒形态（本实现产出），再退回基本形态。
    private static func parseTime(_ text: String) -> Date? {
        if let parsed = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return parsed
        }
        return try? Date(text, strategy: .iso8601)
    }
}
