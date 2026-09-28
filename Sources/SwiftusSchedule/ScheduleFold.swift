import Foundation
import SwiftusFoundation

/// 折叠一段按序事件流，得到活动记录与用过的标识（规格 S8 §6）。
///
/// 传入的应当是会话自身拥有的事件（`Session.ownEvents`），这样 fork 出的会话不会
/// 继承父会话的活动提醒。
public func foldScheduleEvents(_ events: [SessionEvent]) throws -> ScheduleFold {
    var changes: [ScheduleChange] = []
    for event in events where event.type == kScheduleChangeEvent {
        changes.append(try decodeScheduleChange(event.data))
    }
    return try applyScheduleChanges(ScheduleFold(active: [], seenIds: []), changes)
}

/// 按序应用一批已解码变更，返回新的折叠结果（规格 S8 §6）。
///
/// 折叠只接受合法转换：id 复用、指向非活动记录的删除或派发都会抛 ScheduleLogError。
/// 活动记录保持创建顺序；seenIds 保留所有用过的标识（保持首次出现顺序）。
public func applyScheduleChanges(_ folded: ScheduleFold, _ changes: [ScheduleChange]) throws -> ScheduleFold {
    var state = FoldState(folded)
    for change in changes {
        try state.apply(change)
    }
    return state.result()
}

/// 折叠进行态：活动表 + 创建序 + 标识集（含首次出现顺序）。
private struct FoldState {
    private var active: [String: ScheduleRecord] = [:]
    private var order: [String] = []
    private var seen: Set<String> = []
    private var seenOrder: [String] = []

    init(_ folded: ScheduleFold) {
        for record in folded.active {
            active[record.id] = record
            order.append(record.id)
        }
        seen = Set(folded.seenIds)
        seenOrder = folded.seenIds
    }

    mutating func apply(_ change: ScheduleChange) throws {
        if case let .create(record) = change {
            return try applyCreate(record)
        }
        if case let .delete(id) = change {
            return try applyDelete(id)
        }
        if case let .dispatch(id, acceptedAt) = change {
            return try applyDispatch(id: id, acceptedAt: acceptedAt)
        }
    }

    func result() -> ScheduleFold {
        ScheduleFold(active: order.compactMap { active[$0] }, seenIds: seenOrder)
    }

    private mutating func applyCreate(_ record: ScheduleRecord) throws {
        guard !seen.contains(record.id) else {
            throw ScheduleLogError("schedule id \(quoteScheduleId(record.id)) was reused")
        }
        seen.insert(record.id)
        seenOrder.append(record.id)
        active[record.id] = record
        order.append(record.id)
    }

    private mutating func applyDelete(_ id: String) throws {
        guard active.removeValue(forKey: id) != nil else {
            throw ScheduleLogError("schedule delete targets inactive id \(quoteScheduleId(id))")
        }
        order.removeAll { $0 == id }
    }

    private mutating func applyDispatch(id: String, acceptedAt: Date?) throws {
        guard let record = active[id] else {
            throw ScheduleLogError("schedule dispatch targets inactive id \(quoteScheduleId(id))")
        }
        guard let next = try dispatched(record, acceptedAt: acceptedAt) else {
            active.removeValue(forKey: id)
            order.removeAll { $0 == id }
            return
        }
        active[id] = next
    }

    /// 派发转换：一次性记录不得携带 acceptedAt（派发后移除）；every 必须携带并推进，
    /// 耗尽（nil）时移除（规格 S8 §6）。
    private func dispatched(_ record: ScheduleRecord, acceptedAt: Date?) throws -> ScheduleRecord? {
        if record.kind != .every {
            guard acceptedAt == nil else {
                throw ScheduleLogError("one-shot dispatch must not contain acceptedAt")
            }
            return nil
        }
        guard let acceptedAt else {
            throw ScheduleLogError("every dispatch must contain acceptedAt")
        }
        return try resolveEveryOccurrence(record, acceptedAt: acceptedAt).nextScheduledAt
            .map { record.withScheduledAt($0) }
    }
}

/// 分配下一个可读标识，永不复用任何用过的标识（规格 S8 §6）。
public func allocateScheduleId(_ folded: ScheduleFold) -> String {
    let seen = Set(folded.seenIds)
    var sequence = seen.count + 1
    var candidate = "schedule-\(sequence)"
    while seen.contains(candidate) {
        sequence += 1
        candidate = "schedule-\(sequence)"
    }
    return candidate
}
