import Foundation
import SwiftusCore

// MARK: - 常量

/// 固定间隔任务的最小间隔（秒）（规格 S9 §1）。
public let kCronMinEverySeconds: Double = 10

/// 内存与文件两侧的执行历史上限。
public let kCronMaxHistory = 500

/// 运行记录摘要的最大长度（字符）。
public let kCronExcerptLength = 300

/// 任务存储文件的协议版本。
public let kCronStorageVersion = 1

/// 规则键；patch 命中任何一个都视为改动排期。
public let kCronRuleKeys = ["at", "every", "daily", "cron"]

// MARK: - 错误

/// 封闭的 cron 错误码集合（规格 S9 §1）。
public enum CronErrorCode: String, Sendable {
    case invalidTask = "invalid-task"
    case duplicateId = "duplicate-id"
    case notFound = "not-found"
    case configTask = "config-task"
    case deliveryUnavailable = "delivery-unavailable"
    case internalError = "internal_error"
}

/// cron 服务抛出的稳定失败（规格 S9 §1）。
public struct CronException: Error, Equatable {
    public let code: CronErrorCode
    public let message: String

    public init(_ code: CronErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

extension CronException: CustomStringConvertible {
    public var description: String {
        "CronException(\(code.rawValue)): \(message)"
    }
}

// MARK: - 枚举

/// 任务规则种类（每个任务四选一）。
public enum CronRuleKind: String, Sendable {
    case at, every, daily, cron
}

/// 任务来源。
public enum CronTaskOrigin: String, Sendable {
    /// 宿主配置声明的静态任务，运行时不可增删改。
    case config
    /// 运行时添加并持久化的任务。
    case dynamic
}

/// 一条任务运行记录的稳定状态值。
public enum CronRunStatus: String, Sendable {
    /// 已交付宿主（等待执行结果）。
    case delivered
    /// 执行中（事件流语义保留，本端口不主动置位）。
    case running
    /// 执行完成。
    case completed
    /// 执行失败。
    case failed
}

// MARK: - 内部记录

/// 一个任务的内部可变记录（规格 S9 §2）。
///
/// **必须是类**：`enabledOverride` / `lastRunAt` / `firedAt` / `cronParsed` / `cronNext`
/// 都在内存里被就地改写；若用值类型，每次改都要回写任务表。
public final class CronTask {
    public let id: String
    public var prompt: String
    public var at: String?
    public var every: Double?
    public var daily: String?
    public var cron: String?
    public let sessionId: String?
    /// 声明的启停值（创建时归一为布尔）。
    public var enabled: Bool
    public let origin: CronTaskOrigin

    /// 运行时启停覆盖；与声明值一致时归 nil（规格 S9 §2）。
    public var enabledOverride: Bool?
    /// 最近一次成功交付的时刻。
    public var lastRunAt: Date?
    /// at 任务已消费的时刻（触发后不再触发）。
    public var firedAt: Date?
    /// `cron` 的解析缓存；不持久化。
    public var cronParsed: CronExpression?
    /// 缓存的下一个 cron 触发分钟；触发或编辑后失效。
    public var cronNext: Date?

    public init(
        id: String,
        prompt: String,
        at: String? = nil,
        every: Double? = nil,
        daily: String? = nil,
        cron: String? = nil,
        sessionId: String? = nil,
        enabled: Bool = true,
        origin: CronTaskOrigin
    ) {
        self.id = id
        self.prompt = prompt
        self.at = at
        self.every = every
        self.daily = daily
        self.cron = cron
        self.sessionId = sessionId
        self.enabled = enabled
        self.origin = origin
    }

    /// 生效的启停值：覆盖优先于声明值。
    public var isEnabled: Bool {
        enabledOverride ?? enabled
    }
}

// MARK: - 视图

/// 一条任务的模型可见视图（规格 S9 §2）。
public struct CronTaskView: Sendable, Equatable {
    public let id: String
    public let prompt: String
    /// 排期规则（四选一的对象）。
    public let schedule: [String: JSONValue]
    public let enabled: Bool
    public let origin: CronTaskOrigin
    public let sessionId: String?
    public let lastRunAt: Date?
    public let firedAt: Date?
    /// 下一次触发时刻；无待触发返回 nil。
    public let nextRunAt: Date?

    public init(
        id: String,
        prompt: String,
        schedule: [String: JSONValue],
        enabled: Bool,
        origin: CronTaskOrigin,
        sessionId: String? = nil,
        lastRunAt: Date? = nil,
        firedAt: Date? = nil,
        nextRunAt: Date? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.schedule = schedule
        self.enabled = enabled
        self.origin = origin
        self.sessionId = sessionId
        self.lastRunAt = lastRunAt
        self.firedAt = firedAt
        self.nextRunAt = nextRunAt
    }

    /// 序列化为工具结果（日期一律 UTC ISO 串）。
    public var json: [String: JSONValue] {
        [
            "id": .string(id),
            "prompt": .string(prompt),
            "schedule": .object(schedule),
            "enabled": .bool(enabled),
            "origin": .string(origin.rawValue),
            "sessionId": sessionId.map { .string($0) } ?? .null,
            "lastRunAt": CronInstant.format(lastRunAt),
            "firedAt": CronInstant.format(firedAt),
            "nextRunAt": CronInstant.format(nextRunAt),
        ]
    }
}

// MARK: - 时刻格式化

/// 时刻与 UTC ISO 串之间的转换（规格 S9 §1：日期一律 UTC ISO）。
public enum CronInstant {
    /// 格式化为 UTC ISO 串；nil 原样返回。
    public static func format(_ instant: Date?) -> JSONValue {
        guard let instant else { return .null }
        return .string(isoFormatter.string(from: instant))
    }

    static var isoFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    /// 解析 ISO 8601 串（宽容：带不带毫秒、什么偏移都吃）。
    ///
    /// **无时区信息的串按 UTC 解释**。来源的 `DateTime.tryParse` 把这类串当作
    /// **进程本地时区**，本移植改为固定 UTC（有意偏离，见规格 S9 §11）：规则函数
    /// 是纯函数、不持有环境时区，按机器时区解释会让同一个配置文件在不同机器上
    /// 触发时刻不同。需要特定时区的宿主应自己带上偏移。
    public static func parse(_ text: String) -> Date? {
        let optionSets: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ]
        for options in optionSets {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        // 无时区信息的串：`ISO8601DateFormatter` 要求偏移，改用固定 GMT 的 DateFormatter。
        let patterns = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss",
        ]
        for pattern in patterns {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) { return date }
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}

/// JSONValue → Double（int / double 都吃；其余 nil）。
func cronNumber(_ value: JSONValue?) -> Double? {
    switch value {
    case .some(.int(let raw)): return Double(raw)
    case .some(.double(let raw)): return raw
    default: return nil
    }
}
