import Foundation

/// 封闭的 schedule 错误码集合（规格 S8 §1.4）。rawValue 即协议中的稳定字符串。
///
/// 错误码是稳定契约：工具结果里的 `code` 字段直接取这里的 rawValue，模型据此区分
/// 输入错误、规则错误、时间错误与持久日志损坏；新增错误码属于协议变更。
public enum ScheduleErrorCode: String, Sendable {
    /// 提醒内容去空白后为空。
    case invalidPrompt = "invalid_prompt"
    /// 选择器缺失、冲突，或出现未知的创建参数。
    case invalidSelector = "invalid_selector"
    /// 规则本身非法（选择器取值、at 形状、删除参数格式）。
    case invalidRule = "invalid_rule"
    /// time_zone 不是 UTC 或合法的 IANA Area/Location 名。
    case invalidTimeZone = "invalid_time_zone"
    /// 计算出的时刻不严格晚于创建时刻。
    case notFuture = "not_future"
    /// 时刻无法用四位年份的 RFC 3339 UTC 形式表示。
    case timeOutOfRange = "time_out_of_range"
    /// 固定间隔低于 300 秒。
    case frequencyTooHigh = "frequency_too_high"
    /// 会话里的 schedule 变更流已损坏。
    case corruptLog = "corrupt_schedule_log"
    /// 无法确认持久化是否落定。
    case persistenceUncertain = "persistence_uncertain"
    /// 不暴露内部细节的兜底失败。
    case internalError = "internal_error"
    /// 删除目标不存在或已经结束。
    case notFound = "schedule_not_found"
}

/// 可能无法确认落定的管理操作名（规格 S8 §1.4）。
public enum ScheduleOperation: String, Sendable {
    /// 创建一条提醒。
    case create
    /// 列出活动提醒。
    case list
    /// 删除一条提醒。
    case delete
}

/// 模型给出的规则无法成为一条持久记录（规格 S8 §1.4）。
public struct ScheduleInputError: Error, Equatable {
    /// ScheduleErrorCode 中的稳定错误码。
    public let code: ScheduleErrorCode
    /// 面向模型的稳定诊断。
    public let message: String

    public init(_ code: ScheduleErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

extension ScheduleInputError: CustomStringConvertible {
    public var description: String {
        "ScheduleInputError(\(code.rawValue)): \(message)"
    }
}

/// 会话里的持久 schedule 流损坏，或出现了非法转换（规格 S8 §1.4）。
public struct ScheduleLogError: Error, Equatable {
    /// 被违反的具体不变式。
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    /// 固定为 corrupt_schedule_log。
    public var code: ScheduleErrorCode {
        .corruptLog
    }
}

extension ScheduleLogError: CustomStringConvertible {
    public var description: String {
        "ScheduleLogError: \(message)"
    }
}

/// 无法确认持久化是否落定（规格 S8 §1.4）。
///
/// 这不是「失败」：变更可能已经写进会话，也可能没有。调用方应当先用
/// schedule_list 澄清，而不是重试或声称成功。
public struct SchedulePersistenceError: Error, Equatable {
    /// ScheduleOperation 中的操作名。
    public let operation: ScheduleOperation
    /// 已知的目标标识（创建与删除才有）。
    public let id: String?

    public init(operation: ScheduleOperation, id: String? = nil) {
        self.operation = operation
        self.id = id
    }

    /// 固定为 persistence_uncertain。
    public var code: ScheduleErrorCode {
        .persistenceUncertain
    }
}

extension SchedulePersistenceError: CustomStringConvertible {
    public var description: String {
        "SchedulePersistenceError(\(operation.rawValue))"
    }
}
