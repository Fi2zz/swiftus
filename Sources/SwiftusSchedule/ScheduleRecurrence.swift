import Foundation

/// 一次固定间隔决策的产生结果（规格 S8 §7）。
public struct EveryOccurrence: Sendable, Equatable {
    /// 最新一个已到期的锚点对齐发生时点。
    public let occurrenceAt: Date
    /// 第一个严格未来的锚点对齐目标；已经耗尽（超范围）时为 nil。
    public let nextScheduledAt: Date?

    public init(occurrenceAt: Date, nextScheduledAt: Date?) {
        self.occurrenceAt = occurrenceAt
        self.nextScheduledAt = nextScheduledAt
    }
}

/// 计算 record 在 acceptedAt 时点最新一个到期时点及下一个目标（规格 S8 §7）。
///
/// 错过的间隔**永不逐条枚举**：整数运算直接推进到最新到期时点，因此不会回放积压。
public func resolveEveryOccurrence(_ record: ScheduleRecord, acceptedAt: Date) throws -> EveryOccurrence {
    guard record.kind == .every, let everySeconds = record.everySeconds else {
        throw ScheduleLogError("every occurrence requires a fixed-rate record")
    }
    guard acceptedAt >= minFourDigitYearInstant, acceptedAt <= maxFourDigitYearInstant else {
        throw ScheduleLogError("every acceptedAt must be a representable four-digit-year instant")
    }
    guard everySeconds > 0, everySeconds <= kMaxSafeInteger / 1000 else {
        throw ScheduleLogError("every interval milliseconds must be a positive safe integer")
    }
    let interval = Int64(everySeconds) * 1000
    let target = record.scheduledAt.utcMilliseconds
    let accepted = acceptedAt.utcMilliseconds
    guard accepted >= target else {
        throw ScheduleLogError("every dispatch cannot precede the active scheduledAt")
    }
    let occurrence = target + (accepted - target) / interval * interval
    let next = occurrence + interval
    return EveryOccurrence(
        occurrenceAt: Date(utcMilliseconds: occurrence),
        nextScheduledAt: next > maxFourDigitYearMillis ? nil : Date(utcMilliseconds: next)
    )
}
