import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 规划轮的输入（参数封装，规格 S16 §1.3）。
public struct PlanningPhaseInput {
    /// 模型接入。
    public var llm: any LlmProvider
    /// 工具注册表。
    public var tools: ToolRegistry
    /// 绑定会话。
    public var session: Session

    public init(llm: any LlmProvider, tools: ToolRegistry, session: Session) {
        self.llm = llm
        self.tools = tools
        self.session = session
    }
}

/// 规划轮：只下发 `plan_write`，让模型先产出计划；写好后刷新 system 消息
///（规格 S16 §1.3）。返回是否真正跑了规划（未注册 plan_write 时返回 false）。
@ContextTreeActor
@discardableResult
public func runPlanningPhase(
    _ input: PlanningPhaseInput,
    messages: inout [LlmMessage],
    systemText: @ContextTreeActor () -> String
) async throws -> Bool {
    guard let schema = input.tools.describeOne(kPlanToolName) else { return false }
    var planningMessages = [
        LlmMessage(
            "system",
            systemText() + "\n\n先制定一个简洁的执行计划：只调用 \(kPlanToolName) 工具，不要直接回答用户。"
        ),
    ]
    planningMessages.append(contentsOf: messages.dropFirst())
    let result = try await input.llm.chat(LlmRequest(messages: planningMessages, tools: [schema]))
    for call in result.toolCalls where call.name == kPlanToolName {
        _ = await input.tools.call(ToolCall(
            name: call.name,
            callId: call.id,
            arguments: parseToolArguments(call.arguments)
        ))
    }
    if !messages.isEmpty {
        messages[0] = LlmMessage("system", systemText())
    }
    return true
}
