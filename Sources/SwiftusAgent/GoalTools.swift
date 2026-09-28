import SwiftusCore
import SwiftusFoundation

/// `create_goal` 工具名。
public let kCreateGoalToolName = "create_goal"
/// `edit_goal` 工具名。
public let kEditGoalToolName = "edit_goal"
/// `complete_goal` 工具名。
public let kCompleteGoalToolName = "complete_goal"
/// `clear_goal` 工具名。
public let kClearGoalToolName = "clear_goal"

/// 目标服务错误 → 失败结果（规格 S16 §7.5）。
private func goalFailure(_ error: GoalException) -> ToolResult {
    .failure(error.message, error: ToolError(error.code, error.message))
}

/// 创建长期目标（low）。
@ContextTreeActor
public final class CreateGoalTool: Tool {
    private let goal: any GoalService

    public init(goal: any GoalService) {
        self.goal = goal
    }

    public let name = kCreateGoalToolName
    public let description = "创建一个长期目标。每会话至多一个。"

    public let params: [ParamSpec] = [
        .string("text", description: "目标描述", required: true),
        .integer("max_rounds", description: "轮次上限，默认 256"),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        do {
            let text = try context.requireString("text")
            let maxRounds = try context.integer("max_rounds")
            let created = try await goal.create(text, maxRounds: maxRounds)
            return .success("好的，我会持续关注：\(created.text)")
        } catch let error as GoalException {
            return goalFailure(error)
        }
    }
}

/// 编辑目标文本（low）。
@ContextTreeActor
public final class EditGoalTool: Tool {
    private let goal: any GoalService

    public init(goal: any GoalService) {
        self.goal = goal
    }

    public let name = kEditGoalToolName
    public let description = "编辑当前长期目标的描述。"

    public let params: [ParamSpec] = [
        .string("text", description: "新的目标描述", required: true),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        do {
            let text = try context.requireString("text")
            let edited = try await goal.edit(text)
            return .success("好的，目标已更新：\(edited.text)")
        } catch let error as GoalException {
            return goalFailure(error)
        }
    }
}

/// 标记目标完成（low）。
@ContextTreeActor
public final class CompleteGoalTool: Tool {
    private let goal: any GoalService

    public init(goal: any GoalService) {
        self.goal = goal
    }

    public let name = kCompleteGoalToolName
    public let description = "标记当前长期目标为已完成。"

    public func call(_ context: ToolContext) async throws -> ToolResult {
        do {
            try await goal.complete()
            return .success("目标已标记完成。")
        } catch let error as GoalException {
            return goalFailure(error)
        }
    }
}

/// 清除目标（medium，走 approval 确认）。
@ContextTreeActor
public final class ClearGoalTool: Tool {
    private let goal: any GoalService

    public init(goal: any GoalService) {
        self.goal = goal
    }

    public let name = kClearGoalToolName
    public let description = "清除当前长期目标（会丢失所有进度，需用户确认）。"
    public let riskLevel: ToolRisk = .medium

    public func call(_ context: ToolContext) async throws -> ToolResult {
        do {
            try await goal.clear()
            return .success("好的，目标已清除。")
        } catch let error as GoalException {
            return goalFailure(error)
        }
    }
}
