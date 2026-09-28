import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 子 Agent 的默认人设（规格 S16 §6.3）。
public let kDefaultSubAgentPrompt = "你是内部子助手，只完成交办的一件事。只依据工具返回的事实作答，禁止编造；"
    + "完成后直接给出结论简报（尽量简短），不要寒暄、不要反问用户。"

/// 一次子 Agent 委托的结局。
public struct SubAgentResult: Sendable, Equatable {
    /// 状态：success / failed。
    public let status: String
    /// 结论简报（成功）或失败说明。
    public let output: String
    /// 工具调用步数。
    public let rounds: Int
    /// 子 Agent 用过的工具名（按序）。
    public let toolCalls: [String]

    public init(status: String, output: String, rounds: Int = 0, toolCalls: [String] = []) {
        self.status = status
        self.output = output
        self.rounds = rounds
        self.toolCalls = toolCalls
    }

    public var jsonValue: JSONValue {
        .object([
            "status": .string(status),
            "output": .string(output),
            "rounds": .int(Int64(rounds)),
            "tool_calls": .array(toolCalls.map { .string($0) }),
        ])
    }
}

/// `spawn_agent`：把一段自包含的任务委托给隔离子 Agent（规格 S16 §6.3）。
///
/// 子上下文在宿主下派生（随宿主释放），子会话与受限子注册表独立，
/// 跑独立的 AgentLoop，只把最终结果回传主 Agent。
@ContextTreeActor
public final class SpawnAgentTool: Tool {
    /// 宿主上下文：子上下文在其下派生，随宿主释放。
    public let host: Context
    /// 子 Agent 使用的模型（与主 Agent 同一实例，可换）。
    public let llm: any LlmProvider
    /// 主注册表：用于按白名单取工具实例。
    public let tools: ToolRegistry
    /// 未显式传 tools 时的默认白名单；缺省取主注册表里非 high 且非本工具。
    public let defaultTools: [String]?
    /// 默认最大模型调用步数。
    public let maxRounds: Int
    /// 子 Agent 的兜底人设。
    public let subAgentPrompt: String
    /// 子 Agent 的 system prompt 注册表；缺省不用（隔离）。
    public let systemPrompt: SystemPrompt?

    private var seq = 0

    public init(
        host: Context,
        llm: any LlmProvider,
        tools: ToolRegistry,
        defaultTools: [String]? = nil,
        maxRounds: Int = 8,
        subAgentPrompt: String = kDefaultSubAgentPrompt,
        systemPrompt: SystemPrompt? = nil
    ) {
        self.host = host
        self.llm = llm
        self.tools = tools
        self.defaultTools = defaultTools
        self.maxRounds = maxRounds
        self.subAgentPrompt = subAgentPrompt
        self.systemPrompt = systemPrompt
    }

    public let name = "spawn_agent"

    public let description = "把一个自包含的子任务委托给独立的子 Agent 执行，只回结论。"

    public let riskLevel: ToolRisk = .medium

    public let params: [ParamSpec] = [
        .string("task", description: "自包含的子任务描述", required: true),
        .array("tools", items: .string("item"), description: "允许子 Agent 使用的工具名（白名单）"),
        .integer("max_rounds", description: "子 Agent 最大步数"),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        let task = try context.requireString("task")
        let rounds = try context.integer("max_rounds") ?? maxRounds
        let result = try await run(task: task, allowed: allowedTools(try context.array("tools")), maxRounds: rounds)
        return .success(result.output, value: result.jsonValue)
    }

    /// 跑一次委托。子 Agent 的失败也收敛为 SubAgentResult（status=failed）。
    public func run(task: String, allowed: Set<String>, maxRounds: Int) async throws -> SubAgentResult {
        seq += 1
        let childTools = ToolRegistry()
        for name in allowed {
            if let tool = tools.get(name) {
                try childTools.register(tool)
            }
        }
        let childSession = try Session(id: "subagent-\(seq)-\(Int(Date().timeIntervalSince1970 * 1_000_000))")
        let child = host.plugin("subagent\(seq)") { ctx in
            ctx.onDispose { childSession.close() }
        }
        defer { child.dispose() }
        do {
            var config = AgentLoop.Config()
            config.session = childSession
            config.systemPrompt = systemPrompt
            config.defaultSystemPrompt = subAgentPrompt
            config.maxSteps = maxRounds
            let turn = try await AgentLoop(llm: llm, tools: childTools, config: config).run(task)
            return SubAgentResult(
                status: "success",
                output: turn.reply,
                rounds: turn.steps.count,
                toolCalls: turn.steps.map { $0.call.name }
            )
        } catch {
            return SubAgentResult(status: "failed", output: "子 Agent 失败：\(error)")
        }
    }

    /// 白名单解析：显式 tools → defaultTools → 主注册表非 high 且非本工具。
    private func allowedTools(_ requested: [JSONValue]?) -> Set<String> {
        if let requested, !requested.isEmpty {
            return Set(requested.compactMap { item in
                guard let n = item.stringValue, n != name, tools.get(n) != nil else { return nil }
                return n
            })
        }
        if let defaultTools {
            return Set(defaultTools.filter { n in n != name && tools.get(n) != nil })
        }
        return Set(tools.names.filter { n in
            guard n != name, let tool = tools.get(n) else { return false }
            return tool.riskLevel != .high
        })
    }
}

/// spawn_agent 装配的输入（参数封装）。
public struct SpawnAgentConfig {
    /// 宿主上下文（缺省为装配上下文）。
    public var host: Context?
    /// 子 Agent 模型（缺省取上下文 llm）。
    public var llm: (any LlmProvider)?
    /// 主注册表（缺省取上下文 tools）。
    public var tools: ToolRegistry?
    /// 默认白名单。
    public var defaultTools: [String]?
    /// 默认最大步数。
    public var maxRounds = 8
    /// 子 Agent 兜底人设。
    public var subAgentPrompt = kDefaultSubAgentPrompt
    /// 子 Agent system prompt 注册表。
    public var systemPrompt: SystemPrompt?

    public init() {}
}

/// 把 spawn_agent 工具注册到宿主上下文的工具表（规格 S16 §6.3）。
@ContextTreeActor
@discardableResult
public func provideSpawnAgent(
    _ ctx: Context,
    config: SpawnAgentConfig = SpawnAgentConfig()
) throws -> SpawnAgentTool {
    let registry = try config.tools ?? ctx.require(.tools)
    let tool = SpawnAgentTool(
        host: config.host ?? ctx,
        llm: try config.llm ?? ctx.require(.llm),
        tools: registry,
        defaultTools: config.defaultTools,
        maxRounds: config.maxRounds,
        subAgentPrompt: config.subAgentPrompt,
        systemPrompt: config.systemPrompt
    )
    try ctx.effect { try registry.register(tool) }
    return tool
}
