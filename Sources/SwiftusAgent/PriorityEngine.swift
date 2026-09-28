import Foundation

/// 目标优先级（规格 S16 §8.2）。
public struct GoalPriority: Sendable, Equatable {
    /// 被评估的目标。
    public let goal: Goal
    /// 重要性（1-10）。
    public let importance: Int
    /// 紧迫性（1-10）。
    public let urgency: Int
    /// 进度（0.0-1.0）。
    public let progress: Double

    /// 综合得分。
    public var score: Double {
        Double(importance) * 0.5 + Double(urgency) * 0.3 + (1 - progress) * 0.2
    }
}

/// 优先级引擎（规格 S16 §8.2）：纯函数，给一组 Goal 按综合得分排序选下一个。
/// 当前 GoalService 每会话至多一个目标，引擎为未来的多目标场景预留，
/// Runner 用它记录每次选择的决策理由。
public struct PriorityEngine: Sendable {
    public init() {}

    /// 选择下一个目标；空列表返回 nil。按 scoreOf 得分取最高者，
    /// 同分保持列表原序（单趟扫描，严格大于才替换，天然稳定）。
    public func selectNext(_ goals: [Goal], importance: [String: Int]? = nil) -> Goal? {
        var best: Goal?
        var bestScore = -Double.infinity
        for goal in goals {
            let score = scoreOf(goal, importance: importance).score
            if score > bestScore {
                bestScore = score
                best = goal
            }
        }
        return best
    }

    /// 计算目标得分。importance / urgency 缺省 5，可按 goal.id 覆盖。
    public func scoreOf(_ goal: Goal, importance: [String: Int]? = nil, urgency: [String: Int]? = nil) -> GoalPriority {
        let progress = goal.maxRounds <= 0 ? 0 : min(1.0, max(0.0, Double(goal.round) / Double(goal.maxRounds)))
        return GoalPriority(
            goal: goal,
            importance: importance?[goal.id] ?? 5,
            urgency: urgency?[goal.id] ?? 5,
            progress: progress
        )
    }
}
