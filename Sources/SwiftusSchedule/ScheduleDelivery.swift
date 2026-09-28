import Foundation
import SwiftusCore

/// 交付端口（规格 S8 §10.1）：把 framing 文本投递进会话，返回是否成功入队。
///
/// 返回 false 表示当前无法投递（例如会话正在回答），记录保持活动并在下一次
/// 触发时重试。
public typealias ScheduleDelivery = (String) async throws -> Bool

/// 一次交付的结局（规格 S8 §10.1）。
public enum ScheduleDeliveryOutcome: Sendable, Equatable {
    /// framing 已投递、派发记录已写入，且落盘检查点通过。
    case dispatched
    /// 未发生投递或投递被拒绝：不写派发记录，记录保持活动。
    case deferred
    /// 投递抛错：不写派发记录，记录保持活动。
    case failed
    /// 派发记录写入失败：消息可能已经入队，调用方必须停止派发。
    case faulted
    /// 派发记录已写入，但落盘检查点未能确认。
    case uncertain
}

/// 交付一次到期决策，并返回其结局（规格 S8 §10.1 顺序协议）：
/// **先构造完整 framing，再投递，投递成功后才写入派发记录**。
@ContextTreeActor
public func deliverDueDecision(
    decision: DueDecision,
    schedule: SessionSchedule,
    deliver: ScheduleDelivery,
    onWarning: ((String) -> Void)? = nil
) async -> ScheduleDeliveryOutcome {
    let text = renderDueFraming(decision)
    guard !text.isEmpty else { return .deferred }
    guard let queued = await attemptDeliver(text, deliver: deliver, onWarning: onWarning) else {
        return .failed
    }
    guard queued else { return .deferred }
    return await recordDispatched(decision, schedule: schedule, onWarning: onWarning)
}

/// 投递一次；抛错收敛为 nil（failed）。
@ContextTreeActor
private func attemptDeliver(
    _ text: String,
    deliver: ScheduleDelivery,
    onWarning: ((String) -> Void)?
) async -> Bool? {
    do {
        return try await deliver(text)
    } catch {
        warnSchedule(onWarning, "schedule: delivery failed: \(error)")
        return nil
    }
}

/// 投递成功后的派发写入与检查点；写入失败 faulted，检查点失败 uncertain。
@ContextTreeActor
private func recordDispatched(
    _ decision: DueDecision,
    schedule: SessionSchedule,
    onWarning: ((String) -> Void)?
) async -> ScheduleDeliveryOutcome {
    do {
        try recordScheduleDispatch(decision, schedule: schedule)
    } catch {
        warnSchedule(onWarning, "schedule: dispatch append failed: \(error)")
        return .faulted
    }
    do {
        try await schedule.checkpoint(ScheduleOperation.list)
    } catch {
        warnSchedule(onWarning, "schedule: dispatch barrier failed: \(error)")
        return .uncertain
    }
    return .dispatched
}

/// 把一次已投递的决策写入派发历史；固定间隔批次共用同一个决策时点（规格 S8 §10.1）。
@ContextTreeActor
public func recordScheduleDispatch(_ decision: DueDecision, schedule: SessionSchedule) throws {
    if case let .oneShot(record) = decision {
        try schedule.recordDispatch(record.id)
    }
    if case let .everyBatch(reminders, acceptedAt) = decision {
        for due in reminders {
            try schedule.recordDispatch(due.record.id, acceptedAt: acceptedAt)
        }
    }
}

/// 向可选的告警回调报告一次可容错失败。
public func warnSchedule(_ handler: ((String) -> Void)?, _ message: String) {
    handler?(message)
}
