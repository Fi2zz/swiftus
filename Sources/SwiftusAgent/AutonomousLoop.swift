import Foundation
import os
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 自主运行的单轮迭代机制（规格 S16 §8.3）。
///
/// 承载 Runner 的循环主体：约束检查 → 目标选择 → 单轮执行 → 审计/埋点 →
/// 人类介入检查 → 目标推进。时钟、睡眠与停止信号经注入，保证时间窗口相关
/// 行为可确定性测试。
@ContextTreeActor
final class AutonomousLoop {
    /// 被驱动的 Agent Loop。
    let agent: AgentLoop
    /// 目标服务。
    let goal: any GoalService
    /// 绑定的会话（审计归属与关闭检查）。
    let session: Session

    private let policyProvider: @ContextTreeActor () -> any AutonomousPolicy
    private let seams: AutonomousSeams
    private let clock: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let stopSignal: StopSignal

    init(
        agent: AgentLoop,
        goal: any GoalService,
        session: Session,
        policy: @escaping @ContextTreeActor () -> any AutonomousPolicy,
        seams: AutonomousSeams,
        clock: @escaping @Sendable () -> Date,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void,
        stopSignal: StopSignal
    ) {
        self.agent = agent
        self.goal = goal
        self.session = session
        policyProvider = policy
        self.seams = seams
        self.clock = clock
        self.sleeper = sleeper
        self.stopSignal = stopSignal
    }

    /// 执行一轮完整迭代。返回（停止原因, 成本增量）；停止原因非空时不推进目标。
    func iterate(turns: inout [AgentTurn], advanced: inout [String]) async throws -> (StopReason?, Double) {
        if let early = await earlyStop(turnCount: turns.count) {
            return (early, 0)
        }
        guard let active = goal.current else {
            return (.completed, 0)
        }
        let (turn, costDelta) = try await runTurn()
        turns.append(turn)
        await seams.auditTurn(active, turn: turn, costDelta: costDelta)
        seams.emitTurn(active, turn: turn, costDelta: costDelta)
        if let human = await humanCheck(turn) {
            return (human, costDelta)
        }
        if let advancedReason = await advanceGoal(&advanced) {
            return (advancedReason, costDelta)
        }
        return (nil, costDelta)
    }

    /// 约束检查 + 目标状态检查；返回停止原因，nil 表示可以继续。
    private func earlyStop(turnCount: Int) async -> StopReason? {
        if let check = await checkConstraints(turnCount) {
            return check
        }
        return goalStopReason(goal.current)
    }

    /// 预算 / 时间窗口 / 轮次上限检查。
    private func checkConstraints(_ turnCount: Int) async -> StopReason? {
        if let hard = hardStop(turnCount) {
            return hard
        }
        let window = policyProvider().activeWindow
        guard let window, !window.contains(clock()) else { return nil }
        return await windowDecision(window)
    }

    /// 会话 / 预算 / 轮次上限的硬停止检查。
    private func hardStop(_ turnCount: Int) -> StopReason? {
        if session.closed { return .manualStop }
        if seams.cost > policyProvider().dailyBudget { return .budgetExceeded }
        if turnCount >= policyProvider().maxContinuousRounds {
            return .maxRoundsReached
        }
        return nil
    }

    /// 窗口外决策：nextStart 在今天则等待后继续，否则窗口结束。
    /// 等待被 stop 中断时直接返回 manualStop。
    private func windowDecision(_ window: TimeWindow) async -> StopReason? {
        let now = clock()
        let next = window.nextStart(now)
        if !Self.isSameDay(now, next) {
            return .windowEnded
        }
        let interrupted = await stopSignal.sleepUntil(next, clock: clock, sleeper: sleeper)
        return interrupted ? .manualStop : nil
    }

    /// 跑一轮：带单轮时长上限与成本统计。
    ///
    /// 超时经 AgentCancel **真取消**：agent.run 内所有在途操作与取消信号竞速，
    /// 立即以 AgentCancelled 上抛，不再写 assistant / tool 事件，迟到的模型
    /// 结果被丢弃。已实际执行的工具副作用无法回滚（取消机制的固有边界）。
    /// 超时轮按空轮记录。
    private func runTurn() async throws -> (AgentTurn, Double) {
        let before = seams.cost
        let start = ContinuousClock.now
        let cancel = AgentCancel()
        let timer = Task { [weak cancel] in
            try? await Task.sleep(for: .seconds(policyProvider().maxTurnDuration))
            cancel?.cancel()
        }
        defer { timer.cancel() }
        do {
            let turn = try await agent.run(kAutonomousContinuationPrompt, cancel: cancel)
            return (turn, seams.turnCost(turn, before: before))
        } catch is AgentCancelled {
            await seams.audit("autonomous/turn_timeout", data: [
                "durationMs": .int(Int64(milliseconds(from: start))),
            ])
            return (AgentTurn(reply: "", steps: [], messages: []), 0)
        } catch {
            throw error
        }
    }

    /// 人类介入检查：工具越界或策略要求人在环时经审批确认；拒绝则停止。
    private func humanCheck(_ turn: AgentTurn) async -> StopReason? {
        let policy = policyProvider()
        if let violation = policy.firstViolation(turn.steps) {
            let ok = await seams.askApproval(violation, "自主运营使用了策略外工具 \(violation)")
            return ok ? nil : .humanRequired
        }
        if !policy.requireHumanInLoop {
            return nil
        }
        let ok = await seams.askApproval("autonomous/continue", "策略要求人类在环，是否允许自主继续？")
        return ok ? nil : .humanRequired
    }

    /// 推进目标轮次；目标被终态化/阻塞/暂停时返回停止原因，不再推进。
    private func advanceGoal(_ advanced: inout [String]) async -> StopReason? {
        guard let after = goal.current else { return .completed }
        if let afterReason = goalStopReason(after) {
            return afterReason
        }
        try? await goal.advanceRound()
        advanced.append(after.id)
        return nil
    }

    static func isSameDay(_ a: Date, _ b: Date) -> Bool {
        let ca = Calendar.current.dateComponents([.year, .month, .day], from: a)
        let cb = Calendar.current.dateComponents([.year, .month, .day], from: b)
        return ca.year == cb.year && ca.month == cb.month && ca.day == cb.day
    }
}

/// 目标状态检查：无目标/终态 → completed；阻塞/暂停 → humanRequired。
func goalStopReason(_ current: Goal?) -> StopReason? {
    guard let current else { return .completed }
    if current.isTerminal { return .completed }
    if current.status == .blocked || current.status == .paused {
        return .humanRequired
    }
    return nil
}

/// 停止信号（run 期间一次）：sleepUntil 与 stop 竞速，中断返回 true。
/// 状态全在锁盒里（非 actor）：信号是跨域调用面（如界面 stop 按钮）。
final class StopSignal: Sendable {
    private struct State {
        var waiters: [UUID: @Sendable () -> Void] = [:]
        var signaled = false
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    func signal() {
        state.withLock { current -> Void in
            current.signaled = true
            let pending = current.waiters
            current.waiters.removeAll()
            for waiter in pending.values {
                waiter()
            }
        }
    }

    /// 睡到 until；被 stop 中断时返回 true（规格 S16 §8.3）。
    func sleepUntil(
        _ until: Date,
        clock: @escaping @Sendable () -> Date,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void
    ) async -> Bool {
        let wait = until.timeIntervalSince(clock())
        guard wait > 0 else { return false }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            // 注册（锁内）：已 signaled 则立即返回 true。
            let registered = state.withLock { current -> Bool in
                if current.signaled {
                    continuation.resume(returning: true)
                    return false
                }
                current.waiters[token] = {
                    continuation.resume(returning: true)
                }
                return true
            }
            guard registered else { return }
            Task {
                try? await sleeper(wait)
                // 未被 stop 先取走则这里收尾（锁内取，保证唯一 resume）。
                state.withLock { current -> Void in
                    guard current.waiters.removeValue(forKey: token) != nil else { return }
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
