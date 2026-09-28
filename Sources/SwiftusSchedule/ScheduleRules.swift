import Foundation
import SwiftusCore

/// 创建规则（规格 S8 §4）：错误码与顺序属于协议——先校验提醒内容，再校验选择器
/// 本身，最后校验目标时刻是否严格位于未来且在可表示范围内。

/// 规范提醒内容：去首尾空白，并拒绝空内容。
public func normalizePrompt(_ prompt: String) throws -> String {
    let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
        throw ScheduleInputError(.invalidPrompt, "prompt must be non-empty after trimming.")
    }
    return normalized
}

/// 校验延迟规则并构造一条 after 记录。
public func createAfterRecord(
    id: String,
    prompt: String,
    afterSeconds: Int,
    now: Date
) throws -> ScheduleRecord {
    let normalized = try normalizePrompt(prompt)
    guard safePositiveSeconds(afterSeconds) else {
        throw ScheduleInputError(.invalidRule, "after_seconds must be a positive safe integer.")
    }
    return ScheduleRecord(
        id: id,
        kind: .after,
        prompt: normalized,
        scheduledAt: try futureInstant(now.addingTimeInterval(TimeInterval(afterSeconds)), now),
        afterSeconds: afterSeconds
    )
}

/// 校验绝对时刻选择器并构造一条 at 记录。
public func createAtRecord(
    id: String,
    prompt: String,
    at: JSONValue?,
    now: Date
) throws -> ScheduleRecord {
    let normalized = try normalizePrompt(prompt)
    let target = try resolveAtTarget(at)
    return ScheduleRecord(
        id: id,
        kind: .at,
        prompt: normalized,
        scheduledAt: try futureInstant(target, now)
    )
}

/// 校验固定间隔规则并构造一条 every 记录。
public func createEveryRecord(
    id: String,
    prompt: String,
    everySeconds: Int,
    now: Date
) throws -> ScheduleRecord {
    let normalized = try normalizePrompt(prompt)
    guard everySeconds <= kMaxSafeInteger else {
        throw ScheduleInputError(.invalidRule, "every_seconds must be a safe integer.")
    }
    guard everySeconds >= kMinEveryIntervalSeconds else {
        throw ScheduleInputError(
            .frequencyTooHigh,
            "every_seconds must be at least \(kMinEveryIntervalSeconds)."
        )
    }
    return ScheduleRecord(
        id: id,
        kind: .every,
        prompt: normalized,
        scheduledAt: try futureInstant(now.addingTimeInterval(TimeInterval(everySeconds)), now),
        everySeconds: everySeconds
    )
}

/// 用单次墙钟采样派生一条模型可见视图（规格 S8 §1.3；边界含等号）。
public func scheduleView(_ record: ScheduleRecord, _ now: Date) -> ScheduleView {
    ScheduleView(
        record: record,
        state: now < record.scheduledAt ? .scheduled : .overdue
    )
}
