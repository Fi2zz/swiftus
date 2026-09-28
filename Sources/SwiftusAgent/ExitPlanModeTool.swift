import SwiftusCore
import SwiftusFoundation

/// `exit_plan_mode` 工具名（规格 S16 §9.3）。
public let kExitPlanModeToolName = "exit_plan_mode"

/// 提交计划供用户审批（规格 S16 §9.3，low）。
///
/// 批准后 PlanMode.exit 随调用自动发生（工具内完成，模型无需关心）；拒绝时保持
/// Plan Mode 激活，反馈由模型带回修订计划。与 plan_write（写草稿）共存：
/// 先草稿迭代，后定稿提交。
@ContextTreeActor
public final class ExitPlanModeTool: Tool {
    /// 计划提交到的 Plan Mode 服务。
    public let planMode: any PlanMode

    public init(planMode: any PlanMode) {
        self.planMode = planMode
    }

    public let name = kExitPlanModeToolName
    public let description = "提交计划供用户审批。在 plan mode 下使用。"

    public let params: [ParamSpec] = [
        .string("goal", description: "计划目标", required: true),
        .array("steps", items: .string("item"), description: "有序步骤列表", required: true),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        let goal = try context.requireString("goal")
        let raw = try context.array("steps") ?? []
        var steps: [PlanStep] = []
        for item in raw {
            guard let text = item.stringValue else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                steps.append(PlanStep(id: "s\(steps.count + 1)", text: trimmed))
            }
        }
        let approved = await planMode.submitPlan(Plan(goal: goal, steps: steps))
        if approved {
            planMode.exit()
            return .success("Plan approved. Proceeding with execution.")
        }
        return .success("Plan rejected. Please revise based on user feedback.")
    }
}
