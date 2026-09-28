import Foundation
import SwiftusCore

/// 自主策略（规格 S16 §8.1）：定义约束和边界，Capability Seam。
public protocol AutonomousPolicy: Sendable {
    /// 每日预算上限（美元）。
    var dailyBudget: Double { get }
    /// 时间窗口；nil 表示全天。
    var activeWindow: TimeWindow? { get }
    /// 可以自主执行的操作白名单；空集表示不限制。
    var allowedActions: Set<String> { get }
    /// 必须人类确认的操作黑名单；空集表示无黑名单。
    var requireApproval: Set<String> { get }
    /// 最大连续运行轮次。
    var maxContinuousRounds: Int { get }
    /// 单轮最大时长（秒）。
    var maxTurnDuration: TimeInterval { get }
    /// 是否需要人类在环。
    var requireHumanInLoop: Bool { get }
}

extension AutonomousPolicy {
    /// 第一个违反本策略的工具名；无违规返回 nil（规格 S16 §8.1）。
    /// 命中 requireApproval 黑名单，或 allowedActions 非空且未在白名单时视为越界。
    public func firstViolation(_ steps: [AgentStep]) -> String? {
        for step in steps {
            let name = step.call.name
            if requireApproval.contains(name) { return name }
            if !allowedActions.isEmpty && !allowedActions.contains(name) { return name }
        }
        return nil
    }
}

/// 默认自主策略（规格 S16 §8.1）：无预算限制、全天、不限制工具、8 轮、
/// 单轮 5 分钟、不强制人类在环。
public struct DefaultAutonomousPolicy: AutonomousPolicy {
    public let dailyBudget: Double
    public let activeWindow: TimeWindow?
    public let allowedActions: Set<String>
    public let requireApproval: Set<String>
    public let maxContinuousRounds: Int
    public let maxTurnDuration: TimeInterval
    public let requireHumanInLoop: Bool

    public init(
        dailyBudget: Double = .infinity,
        activeWindow: TimeWindow? = nil,
        allowedActions: Set<String> = [],
        requireApproval: Set<String> = [],
        maxContinuousRounds: Int = 8,
        maxTurnDuration: TimeInterval = 300,
        requireHumanInLoop: Bool = false
    ) {
        self.dailyBudget = dailyBudget
        self.activeWindow = activeWindow
        self.allowedActions = allowedActions
        self.requireApproval = requireApproval
        self.maxContinuousRounds = maxContinuousRounds
        self.maxTurnDuration = maxTurnDuration
        self.requireHumanInLoop = requireHumanInLoop
    }
}

/// 时间窗口（规格 S16 §8.1）。start / end 是 0-23 点内的一天时刻，支持跨午夜
///（start > end，如 22:00-06:00）；end 允许到 48 小时内。端点含。
public struct TimeWindow: Sendable, Equatable {
    /// 开始时刻（0-23 点内）。
    public let start: Duration
    /// 结束时刻（< 48 小时）。
    public let end: Duration

    /// start 必须 0-23 点内；end 必须 < 48 小时，否则快速失败。
    public init(start: Duration, end: Duration) throws {
        let startSec = Int(start.components.seconds)
        let endSec = Int(end.components.seconds)
        guard startSec >= 0, startSec < 86_400 else {
            throw TimeWindowError.invalidStart
        }
        guard endSec < 172_800 else {
            throw TimeWindowError.invalidEnd
        }
        self.start = start
        self.end = end
    }

    /// time 是否落在窗口内（含端点）。
    public func contains(_ time: Date) -> Bool {
        let t = timeOfDay(time)
        if start <= end {
            return t >= start && t <= end
        }
        return t >= start || t <= end // 跨午夜
    }

    /// from 之后窗口的下一次开始时刻。
    public func nextStart(_ from: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var components = calendar.dateComponents([.year, .month, .day], from: from)
        components.hour = startSeconds / 3600 % 24
        components.minute = startSeconds % 3600 / 60
        components.second = 0
        let candidate = calendar.date(from: components) ?? from
        if candidate > from {
            return candidate
        }
        return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    private var startSeconds: Int {
        Int(start.components.seconds)
    }

    private var endSeconds: Int {
        Int(end.components.seconds)
    }

    private func timeOfDay(_ time: Date) -> Duration {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: time)
        let seconds = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
        return Duration(secondsComponent: Int64(seconds), attosecondsComponent: 0)
    }
}

/// 时间窗口配置错误。
public enum TimeWindowError: Error, Equatable {
    /// start 不在 0-23 点内。
    case invalidStart
    /// end 不小于 48 小时。
    case invalidEnd
}

/// 预算能力缝（规格 S16 §8.1）：提供当日累计成本（美元）。
/// 不提供时视为无预算限制。
public protocol CostTracker: Sendable {
    /// 当日累计成本。
    var todayCost: Double { get }
}
