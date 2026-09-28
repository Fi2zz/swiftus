import Foundation
import SwiftusCore
import SwiftusFoundation

/// 计划变更事件类型（规格 S16 §1.1）。
public let kPlanEvent = "plan/updated"

/// 规划工具名。
public let kPlanToolName = "plan_write"

/// 计划的一步。
public struct PlanStep: Sendable, Equatable {
    /// 步骤 id。
    public let id: String
    /// 步骤描述。
    public let text: String
    /// 是否已完成。
    public let done: Bool

    public init(id: String, text: String, done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }

    public init(jsonValue: JSONValue) {
        let object = jsonValue.objectValue ?? [:]
        id = object["id"]?.stringValue ?? ""
        text = object["text"]?.stringValue ?? ""
        done = object["done"] == .bool(true)
    }

    public var jsonValue: JSONValue {
        .object([
            "id": .string(id),
            "text": .string(text),
            "done": .bool(done),
        ])
    }
}

/// 一份执行计划。
public struct Plan: Sendable, Equatable {
    /// 任务目标。
    public let goal: String
    /// 有序步骤。
    public let steps: [PlanStep]

    public init(goal: String, steps: [PlanStep] = []) {
        self.goal = goal
        self.steps = steps
    }

    public init(jsonValue: JSONValue) {
        let object = jsonValue.objectValue ?? [:]
        goal = object["goal"]?.stringValue ?? ""
        steps = (object["steps"]?.arrayValue ?? []).map(PlanStep.init(jsonValue:))
    }

    public var jsonValue: JSONValue {
        .object([
            "goal": .string(goal),
            "steps": .array(steps.map(\.jsonValue)),
        ])
    }

    /// 面向模型/日志的可读摘要（规格 S16 §1.1 逐行形状）。
    public func summary() -> String {
        var buffer = "目标：\(goal)"
        for (index, step) in steps.enumerated() {
            buffer += "\n\(index + 1). [\(step.done ? "x" : " ")] \(step.text)"
        }
        return buffer
    }
}

/// 读取会话里最新的计划；没有则返回 nil（规格 S16 §1.1：倒序取最后一条）。
@ContextTreeActor
public func readPlan(_ session: Session) -> Plan? {
    for event in session.events.reversed() where event.type == kPlanEvent {
        guard let data = event.data, case .object = data else { continue }
        return Plan(jsonValue: data)
    }
    return nil
}

/// 把计划写入会话（追加一条 plan/updated 事件）。
@ContextTreeActor
public func writePlan(_ session: Session, plan: Plan) throws {
    try session.append(kPlanEvent, data: plan.jsonValue)
}

/// 计划注入 system prompt 的片段；无计划时为空串。
@ContextTreeActor
public func planSection(_ session: Session?) -> String {
    guard let session, let plan = readPlan(session) else { return "" }
    return "[当前计划]\n\(plan.summary())"
}

/// `plan_write` 工具：写入/更新当前会话的计划（规格 S16 §1.2）。
@ContextTreeActor
public final class PlanTool: Tool {
    /// 计划持久化到的会话。
    public let session: Session

    public init(session: Session) {
        self.session = session
    }

    public let name = kPlanToolName

    public let description = "制定或更新当前任务的执行计划（目标 + 有序步骤）。"

    public let params: [ParamSpec] = [
        .string("goal", description: "任务目标", required: true),
        .array("steps", items: .string("item"), description: "按顺序的步骤"),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        let goal = try context.requireString("goal")
        let raw = try context.array("steps") ?? []
        var steps: [PlanStep] = []
        for (index, item) in raw.enumerated() {
            let text = planItemText(item).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                steps.append(PlanStep(id: "s\(index + 1)", text: text))
            }
        }
        let plan = Plan(goal: goal, steps: steps)
        try writePlan(session, plan: plan)
        return .success(plan.summary(), value: plan.jsonValue)
    }
}

/// steps 元素的字符串化（Dart `'${item}'` 插值的近义：字符串直取、null 为 "null"、
/// 其余标量与复合形状取 JSON 文本）。
private func planItemText(_ value: JSONValue) -> String {
    if case let .string(text) = value { return text }
    if case .null = value { return "null" }
    if let data = try? value.jsonData() { return String(decoding: data, as: UTF8.self) }
    return ""
}

/// 把 plan_write 工具注册到工具表（规格 S16 §1.2）；随上下文释放撤销。
@ContextTreeActor
@discardableResult
public func providePlanTool(
    _ ctx: Context,
    session: Session,
    tools: ToolRegistry? = nil
) throws -> PlanTool {
    let registry = try tools ?? ctx.require(.tools)
    let tool = PlanTool(session: session)
    try ctx.effect { try registry.register(tool) }
    return tool
}
