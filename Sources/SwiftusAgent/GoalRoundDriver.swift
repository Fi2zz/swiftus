import SwiftusCore

/// 续行提示：驱动器代用户注入的下一轮输入（规格 S16 §7.4）。
public let kGoalContinuationPrompt = "[系统] 继续推进当前目标。"

/// 续行决策。
public enum GoalContinuation: Sendable, Equatable {
    /// 继续下一轮。
    case proceed
    /// 等待用户输入。
    case wait
    /// 已停止（终态、阻塞或达到轮次上限）。
    case stop
}

/// Goal 续行驱动器（规格 S16 §7.4）：读 GoalService 状态，驱动 AgentLoop 续行。
@ContextTreeActor
public final class GoalRoundDriver {
    /// 目标服务。
    public let goal: any GoalService
    /// 被续行的 Agent Loop。
    public let agent: AgentLoop

    public init(goal: any GoalService, agent: AgentLoop) {
        self.goal = goal
        self.agent = agent
    }

    /// 判断是否应该继续。
    public func shouldContinue() async -> GoalContinuation {
        guard let current = goal.current else { return .wait }
        if current.status == .completed || current.status == .cleared || current.status == .blocked {
            return .stop
        }
        if current.status == .paused {
            return .wait
        }
        return await activeDecision(current)
    }

    /// 推进一轮。由 Agent Loop 在每轮收口后调用；返回 nil 表示停止续行。
    public func advance(cancel: AgentCancel? = nil) async throws -> AgentTurn? {
        guard await shouldContinue() == .proceed else { return nil }
        try await goal.advanceRound()
        guard await shouldContinue() == .proceed else { return nil }
        return try await agent.run(kGoalContinuationPrompt, cancel: cancel)
    }

    private func activeDecision(_ current: Goal) async -> GoalContinuation {
        guard current.round < current.maxRounds else {
            _ = try? await goal.block(kGoalRoundLimitReason)
            return .stop
        }
        return .proceed
    }
}

/// 'goalRoundDriver' 服务键。
extension ServiceKey where Service == GoalRoundDriver {
    public static let goalRoundDriver = ServiceKey<GoalRoundDriver>("goalRoundDriver")
}
