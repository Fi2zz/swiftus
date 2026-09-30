import SwiftusCore
import SwiftusFoundation
import SwiftusLLM
import SwiftusMCP
import SwiftusSkill

/// 装配好的离线 Demo 场景。
public struct DemoScenario {
    public let context: Context
    public let loop: MiniAgentLoop
    public let llm: ScriptedLlm
    /// 已装配的 MCP 注册表（Demo 用进程内 server，不连网络）。
    public let mcp: McpRegistry
}

/// 装配 W1 离线 Demo 的 Context 树与脚本化模型（验收：提问 → 工具调用 → 回填 → 收口）。
///
/// 场景设计覆盖全部五块拼图：
/// 1. 模型从技能目录看到 `calculator-manners`，先用 `skill` 工具加载它；
/// 2. 按技能指令（『先说「我来算一下」』）发起 `add` 调用；
/// 3. 拿到结果后收口回答。
///
/// 第 4 块是 S11 的 MCP：装配一台进程内 MCP server，它的工具以 `server__tool`
/// 进同一张工具表，模型照常调用——「外部 server 的工具」与「本地工具」在模型眼里
/// 没有区别，这就是接 MCP 的意义。
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

    // S11：装配一台 MCP server（进程内替身；真实场景传 McpServerConfig）。
    let mcp = try await provideMcp(
        app,
        [try McpServerConfig(name: "demo", type: .stdio, command: "demo-in-process")],
        transportFactory: { _ in DemoMcpTransport() }
    )

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
            // 调 MCP server 上的工具（全名带 server 前缀，保持调用日志里的归属）。
            var result = LlmResult(content: "算完了，再让 MCP server 复述一遍", provider: "scripted", model: "offline")
            result.toolCalls = [LlmToolCall(
                id: "call_3",
                name: "demo__shout",
                arguments: #"{"text":"42"}"#
            )]
            return result
        },
        { _ in
            LlmResult(content: "19 + 23 = 42，算完了；MCP server 复述为 42!。", provider: "scripted", model: "offline")
        },
    ])

    let systemText = prompt.render(prompt.assemble())
    let loop = MiniAgentLoop(llm: scripted, tools: tools, systemPrompt: systemText)
    return DemoScenario(context: app, loop: loop, llm: scripted, mcp: mcp)
}
