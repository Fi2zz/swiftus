import Foundation
import os
import SwiftusCore
import SwiftusFoundation

/// GoalService 的默认实现（规格 S16 §7.3）。
///
/// 只负责目标状态机：每会话至多一个当前目标，状态变更整值替换（写一条
/// goal/changed 事件，恢复时折叠最后一条），fork 不继承。
@ContextTreeActor
public final class DefaultGoalService: GoalService {
    /// 新建目标缺省的轮次上限。
    public let defaultMaxRounds: Int

    private let seams: GoalSeams
    private var stored: Goal?
    private var disposed = false

    private struct State {
        var subscribers: [UUID: AsyncStream<Goal>.Continuation] = [:]
        var closed = false
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// 各 seam 显式传入优先；缺省时从 ctx 惰性解析；再缺省则降级。
    public init(
        session: Session? = nil,
        prompt: SystemPrompt? = nil,
        approval: (any Approval)? = nil,
        telemetry: (any Telemetry)? = nil,
        ctx: Context? = nil,
        defaultMaxRounds: Int = 256
    ) {
        seams = GoalSeams(session: session, prompt: prompt, approval: approval, telemetry: telemetry, ctx: ctx)
        self.defaultMaxRounds = defaultMaxRounds
        if let resolved = seams.resolveSession() {
            restore(resolved)
        }
    }

    public var current: Goal? {
        guard let goal = stored, goal.status != .cleared else { return nil }
        return goal
    }

    public var changes: AsyncStream<Goal> {
        AsyncStream { continuation in
            let token = UUID()
            state.withLock { current -> Void in
                if current.closed {
                    continuation.finish()
                } else {
                    current.subscribers[token] = continuation
                }
            }
            continuation.onTermination = { [state] _ in
                state.withLock { current -> Void in
                    current.subscribers.removeValue(forKey: token)
                }
            }
        }
    }

    public func create(_ text: String, maxRounds: Int? = nil) async throws -> Goal {
        if let existing = current, !existing.isTerminal {
            throw GoalException("already_exists", "当前已有进行中的目标，请先完成或清除。")
        }
        let now = Date()
        let goal = Goal(
            id: "goal-\(Int(now.timeIntervalSince1970 * 1_000_000))",
            text: text,
            status: .active,
            round: 0,
            maxRounds: maxRounds ?? defaultMaxRounds,
            createdAt: now,
            updatedAt: now,
            revisions: [GoalRevision(text: text, revisedAt: now)]
        )
        commit(goal, eventName: "goal.created")
        return goal
    }

    public func edit(_ text: String) async throws -> Goal {
        let goal = try requireLiveGoal(current, action: "编辑")
        if goal.status == .blocked {
            throw GoalException("invalid_status", "目标处于阻塞状态，恢复后才能编辑。")
        }
        let now = Date()
        let next = goal.copyWith(
            text: text,
            updatedAt: now,
            revisions: goal.revisions + [GoalRevision(text: text, revisedAt: now)]
        )
        commit(next, eventName: "goal.edited")
        return next
    }

    public func pause() async throws -> Goal {
        let goal = try requireLiveGoal(current, action: "暂停")
        guard goal.status == .active else {
            throw GoalException("invalid_status", "仅活动的目标可暂停。")
        }
        let next = goal.copyWith(status: .paused, updatedAt: Date())
        commit(next, eventName: "goal.paused")
        return next
    }

    public func resume() async throws -> Goal {
        let goal = try requireLiveGoal(current, action: "恢复")
        let resumable = goal.status == .paused || goal.status == .blocked
        guard resumable else {
            throw GoalException("invalid_status", "仅暂停或阻塞的目标可恢复。")
        }
        let next = goal.copyWith(status: .active, updatedAt: Date(), blockReason: .some(nil))
        commit(next, eventName: "goal.resumed")
        return next
    }

    public func block(_ reason: String) async throws -> Goal {
        let goal = try requireLiveGoal(current, action: "阻塞")
        let next = goal.copyWith(status: .blocked, updatedAt: Date(), blockReason: .some(reason))
        commit(next, eventName: "goal.blocked")
        return next
    }

    public func complete() async throws -> Goal {
        let goal = try requireLiveGoal(current, action: "完成")
        try await seams.confirm("complete_goal", "完成当前目标会结束长期推进，确认？", goal)
        let next = goal.copyWith(status: .completed, updatedAt: Date())
        commit(next, eventName: "goal.completed")
        return next
    }

    public func clear() async throws -> Goal {
        let goal = try requireAnyGoal(stored, action: "清除")
        try await seams.confirm("clear_goal", "清除当前目标会丢失所有进度，确认？", goal)
        let next = goal.copyWith(status: .cleared, updatedAt: Date())
        commit(next, eventName: "goal.cleared")
        return next
    }

    public func advanceRound() async throws {
        let goal = try requireLiveGoal(current, action: "推进")
        guard goal.status == .active else {
            throw GoalException("invalid_status", "仅活动的目标可推进轮次。")
        }
        let now = Date()
        if goal.round + 1 >= goal.maxRounds {
            commit(
                goal.copyWith(
                    status: .blocked,
                    round: goal.maxRounds,
                    updatedAt: now,
                    blockReason: .some(kGoalRoundLimitReason)
                ),
                eventName: "goal.blocked"
            )
            return
        }
        commit(goal.copyWith(round: goal.round + 1, updatedAt: now), eventName: "goal.advanced")
    }

    public func restore(_ session: Session) {
        seams.bindSession(session)
        stored = restoreGoalState(session)
        seams.syncSection { self.current }
    }

    public func dispose() {
        guard !disposed else { return }
        disposed = true
        seams.detachSection()
        let subscribers: [AsyncStream<Goal>.Continuation] = state.withLock { current in
            current.closed = true
            let alive = Array(current.subscribers.values)
            current.subscribers.removeAll()
            return alive
        }
            // 锁内只取出订阅者、锁外再 finish：finish() 会同步触发 onTermination，
            // 而 onTermination 要再进同一把锁（OSAllocatedUnfairLock 不可重入）。
        for subscriber in subscribers {
            subscriber.finish()
        }
    }

    private func commit(_ next: Goal, eventName: String) {
        guard !disposed else { return }
        stored = next
        seams.appendEvent(next)
        seams.syncSection { self.current }
        state.withLock { current -> Void in
            guard !current.closed else { return }
            for subscriber in current.subscribers.values {
                subscriber.yield(next)
            }
        }
        seams.emit(eventName, next)
    }
}

/// 取当前目标；无目标或已终态时抛 GoalException（invalid_status）。
private func requireLiveGoal(_ goal: Goal?, action: String) throws -> Goal {
    guard let goal, !goal.isTerminal else {
        throw GoalException("invalid_status", "当前没有可\(action)的目标。")
    }
    return goal
}

/// 取存储目标（含终态）；无目标时抛 GoalException（no_goal）。
private func requireAnyGoal(_ goal: Goal?, action: String) throws -> Goal {
    guard let goal else {
        throw GoalException("no_goal", "当前没有可\(action)的目标。")
    }
    return goal
}
