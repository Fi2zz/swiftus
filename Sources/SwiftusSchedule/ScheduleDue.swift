import Foundation

/// 一次到期决策的结果（规格 S8 §8）。
public enum DueDecision: Sendable, Equatable {
    /// 当前没有到期记录，可选择安排一次唤醒；target 严格晚于决策时刻，nil 保持静默。
    case wait(Date?)
    /// 交付一条到期的一次性提醒。
    case oneShot(ScheduleRecord)
    /// 交付一批到期的固定间隔提醒，整批共用同一个决策时点。
    case everyBatch(reminders: [ScheduleDue], acceptedAt: Date)
}

/// 选定一次到期决策（规格 S8 §8）：一次性到期优先且一次只交付一条；
/// 否则 every 批次（每条记录只贡献最新一个发生时点）；否则等待或静默。
public func dueDecision(_ folded: ScheduleFold, _ now: Date) throws -> DueDecision {
    if let first = targetsAt(folded.active, now: now, recurring: false).first {
        return .oneShot(first)
    }
    let recurring = targetsAt(folded.active, now: now, recurring: true)
    if !recurring.isEmpty {
        let reminders = try recurring.map { record in
            ScheduleDue(
                record: record,
                occurrenceAt: try resolveEveryOccurrence(record, acceptedAt: now).occurrenceAt
            )
        }
        return .everyBatch(reminders: reminders, acceptedAt: now)
    }
    return .wait(nextTarget(folded.active, now: now))
}

/// 到期目标（scheduledAt <= now，含等号），按（目标时间, 创建序）排序。
private func targetsAt(_ active: [ScheduleRecord], now: Date, recurring: Bool) -> [ScheduleRecord] {
    active.enumerated()
        .filter { ($0.element.kind == .every) == recurring && $0.element.scheduledAt <= now }
        .sorted { left, right in
            if left.element.scheduledAt != right.element.scheduledAt {
                return left.element.scheduledAt < right.element.scheduledAt
            }
            return left.offset < right.offset
        }
        .map(\.element)
}

/// 严格晚于 now 的最小目标；没有未来记录为 nil。
private func nextTarget(_ active: [ScheduleRecord], now: Date) -> Date? {
    active.map(\.scheduledAt).filter { $0 > now }.min()
}
