import SwiftusCore
import SwiftusFoundation
import SwiftusLLM
import SwiftusSkill

/// 装配好的离线 Demo 场景。
public struct DemoScenario {
    public let context: Context
    public let loop: MiniAgentLoop
    public let llm: ScriptedLlm
}

/// 装配 W1 离线 Demo 的 Context 树与脚本化模型（验收：提问 → 工具调用 → 回填 → 收口）。
///
/// 场景设计覆盖全部五块拼图：
/// 1. 模型从技能目录看到 `calculator-manners`，先用 `skill` 工具加载它；
/// 2. 按技能指令（『先说「我来算一下」』）发起 `add` 调用；
/// 3. 拿到结果后收口回答。
@ContextTreeActor
public func buildDemoScenario() async throws -> DemoScenario {
    let app = Context.root(name: "demo")
    let tools = try provideTools(app)
    let prompt = try provideSystemPrompt(app)
    let registry = try await provideSkillRegistry(app)
    _ = try provideSkillCatalog(app)
    _ = try provideSkillTool(app)

    try registry.register(SkillRegistration(
        name: "calculator-manners",
        description: "做算术时的礼仪",
        content: "调用 add 工具前，先说『我来算一下』。"
    ))
    await registry.refresh()

    try tools.fn("add", description: "两个整数相加", params: [
        .integer("a", required: true),
        .integer("b", required: true),
    ]) { context in
        let lhs = try context.integer("a") ?? 0
        let rhs = try context.integer("b") ?? 0
        return .success("\(lhs + rhs)")
    }

    let scripted = ScriptedLlm(responses: [
        { _ in
            var result = LlmResult(content: "", provider: "scripted", model: "offline")
            result.toolCalls = [LlmToolCall(
                id: "call_1",
                name: "skill",
                arguments: #"{"name":"calculator-manners"}"#
            )]
            return result
        },
        { _ in
            var result = LlmResult(content: "我来算一下", provider: "scripted", model: "offline")
            result.toolCalls = [LlmToolCall(
                id: "call_2",
                name: "add",
                arguments: #"{"a":19,"b":23}"#
            )]
            return result
        },
        { _ in
            LlmResult(content: "19 + 23 = 42，算完了。", provider: "scripted", model: "offline")
        },
    ])

    let systemText = prompt.render(prompt.assemble())
    let loop = MiniAgentLoop(llm: scripted, tools: tools, systemPrompt: systemText)
    return DemoScenario(context: app, loop: loop, llm: scripted)
}
