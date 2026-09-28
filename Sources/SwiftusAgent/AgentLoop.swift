import Foundation
import SwiftusCompaction
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// Agent Loop（规格 S4 §6 + S16 §4）——调模型、跑工具、回填结果，直到收口。
/// 组装 system（SystemPrompt + 摘要 + 当前计划）→ planning 规划轮（可选）→
/// router 快路径（可选）→ 循环（模型 → 工具（→ 反思重试）→ 回填）→ 收口。
/// 记忆 / goal 续行 / telemetry / eval 等随后续刀接入。
@ContextTreeActor
public final class AgentLoop {
    /// 可调旋钮（构造参数封装）。
    public struct Config {
        /// 绑定的会话；nil 表示不落事件（临时对话）。
        public var session: Session?
        /// system prompt 注册表；nil 时用 defaultSystemPrompt。
        public var systemPrompt: SystemPrompt?
        /// 历史压缩器；nil 表示不压缩。
        public var compactor: (any CompactionEngine)?
        /// 长记忆库；nil 表示不召回/不记录。
        public var memory: MemoryStore?
        /// 每轮召回的长期记忆条数。
        public var memoryLimit = 5
        /// 工具执行后的自省器；nil 表示不反思。
        public var reflector: Reflector?
        /// 调模型前的确定性路由器；nil 表示不路由（直接落模型）。
        public var router: (any Router)?
        /// 是否在无计划时先跑一次规划轮（需注册 plan_write）。
        public var planning = false
        /// 单轮最大模型调用步数。
        public var maxSteps = 8
        /// 未提供 systemPrompt 时的兜底人设。
        public var defaultSystemPrompt = "你是一个可靠的助手。需要外部信息或操作时调用工具；否则直接回答。"
        /// 每轮的观察口（Observability 埋点）：`agent.round` / `agent.finished`。
        public var onEvent: (@ContextTreeActor (String, [String: JSONValue]) -> Void)?
        /// 流式增量回调：模型每产出一个事件即透传给宿主；nil 不透传。
        public var onStream: (@ContextTreeActor (LlmStreamEvent) -> Void)?

        public init() {}
    }

    /// 一轮的进行态：消息序列 + 工具步骤 + 用量（参数封装）。
    private struct TurnState {
        var messages: [LlmMessage]
        var steps: [AgentStep] = []
        var usages: [[String: JSONValue]] = []
    }

    /// 模型接入。
    public let llm: any LlmProvider
    /// 工具注册表。
    public let tools: ToolRegistry
    /// 运行配置。
    public let config: Config

    private var historyStart = 0
    private var needsReplan = false

    public init(llm: any LlmProvider, tools: ToolRegistry, config: Config = Config()) {
        self.llm = llm
        self.tools = tools
        self.config = config
    }

    /// 绑定的会话。
    public var session: Session? {
        config.session
    }

    /// 跑一轮：从 userInput 到最终文本回复（规格 S16 §4 数据流）。
    ///
    /// cancel 非空时，模型调用、工具执行与路由都与其竞速；取消后本方法以
    /// AgentCancelled 结束（结果丢弃，调用方可立即开始新一轮）。
    @discardableResult
    public func run(
        _ userInput: String,
        cancel: AgentCancel? = nil,
        images: [LlmImage] = []
    ) async throws -> AgentTurn {
        let session = config.session
        try ensureSessionOpen(session)
        try appendUserEvent(session, input: userInput, images: images)
        try await compactIfConfigured()
        if let memory = config.memory {
            try await memory.load()
        }
        var state = TurnState(messages: initialMessages(userInput))
        try await planIfNeeded(state: &state, userInput: userInput)
        if let router = config.router {
            let routed = try await raceRoute(router, input: userInput, cancel: cancel)
            if case let .reply(text) = routed {
                return try await finish(state: state, reply: text, userInput: userInput)
            }
            if case let .tools(calls) = routed {
                try await runPrepared(calls, state: &state, cancel: cancel)
            }
        }
        return try await runSteps(&state, userInput: userInput, cancel: cancel)
    }

    /// 模型调用循环：模型 → 工具（→ 反思重试）→ 回填，直至收口或跑满步数。
    private func runSteps(
        _ state: inout TurnState,
        userInput: String,
        cancel: AgentCancel?
    ) async throws -> AgentTurn {
        for step in 0..<config.maxSteps {
            try ensureSessionOpen(config.session)
            try await replanIfNeeded(state: &state, userInput: userInput)
            let result = try await callModel(messages: state.messages, cancel: cancel)
            state.usages.append(result.usage)
            config.onEvent?("agent.round", [
                "step": .int(Int64(step)),
                "toolCalls": .int(Int64(result.toolCalls.count)),
                "contentLength": .int(Int64(result.content.count)),
            ])
            if result.toolCalls.isEmpty {
                let reply = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return try await finish(state: state, reply: reply, userInput: userInput)
            }
            state.messages.append(assistantMessage(result))
            try appendAssistantEvent(config.session, result: result)
            try await runToolCalls(result.toolCalls, state: &state, task: userInput, cancel: cancel)
        }
        return try await finish(state: state, reply: "（已达到最大步数 \(config.maxSteps)，未收口）", userInput: userInput)
    }

    /// 执行一组模型下发或预置的工具调用：逐个执行（可反思重试）并回填。
    private func runToolCalls(
        _ calls: [LlmToolCall],
        state: inout TurnState,
        task: String,
        cancel: AgentCancel?
    ) async throws {
        for call in calls {
            var outcome = try await invoke(call, cancel: cancel)
            outcome = try await reflectIfConfigured(call: call, outcome: outcome, task: task, cancel: cancel)
            state.messages.append(.toolResult(call.id, outcome.content))
            try appendToolResultEvent(config.session, call: call, outcome: outcome)
            state.steps.append(AgentStep(call: call, result: outcome))
        }
    }

    /// 执行一组预置工具调用（RouteTools）：作为一条 assistant 消息 + 若干
    /// tool 结果写入历史，供后续模型调用据此收口（规格 S16 §3）。
    private func runPrepared(_ calls: [LlmToolCall], state: inout TurnState, cancel: AgentCancel?) async throws {
        var assistant = LlmMessage("assistant", "")
        assistant.toolCalls = calls
        state.messages.append(assistant)
        try appendPreparedAssistantEvent(calls)
        for call in calls {
            let outcome = try await invoke(call, cancel: cancel)
            state.messages.append(.toolResult(call.id, outcome.content))
            try appendToolResultEvent(config.session, call: call, outcome: outcome)
            state.steps.append(AgentStep(call: call, result: outcome))
        }
    }

    /// 无计划时先跑一次规划轮（规格 S16 §1.4）。
    private func planIfNeeded(state: inout TurnState, userInput: String) async throws {
        guard config.planning, let session = config.session, readPlan(session) == nil else { return }
        try await planningPhase(state: &state, userInput: userInput)
    }

    /// 反思置位后，下一步开头重跑规划轮（规格 S16 §1.4）。
    private func replanIfNeeded(state: inout TurnState, userInput: String) async throws {
        guard needsReplan, config.planning, config.session != nil else { return }
        needsReplan = false
        try await planningPhase(state: &state, userInput: userInput)
    }

    private func planningPhase(state: inout TurnState, userInput: String) async throws {
        guard let session = config.session else { return }
        let input = PlanningPhaseInput(llm: llm, tools: tools, session: session)
        try await runPlanningPhase(input, messages: &state.messages, systemText: { self.systemText(userInput) })
    }

    /// 路由判断与取消竞速。
    private func raceRoute(_ router: any Router, input: String, cancel: AgentCancel?) async throws -> RouteDecision {
        guard let cancel else { return try await router.route(input) }
        return try await cancel.race { try await router.route(input) }
    }

    /// 工具执行后的反思（规格 S16 §2.3）；未装配时原样返回。
    private func reflectIfConfigured(
        call: LlmToolCall,
        outcome: ToolResult,
        task: String,
        cancel: AgentCancel?
    ) async throws -> ToolResult {
        guard let reflector = config.reflector else { return outcome }
        let context = ReflectionContext(
            tools: tools,
            task: task,
            plan: config.session.flatMap(readPlan),
            invoke: { [self, cancel] retryCall in try await invoke(retryCall, cancel: cancel) },
            onReplan: { [self] in needsReplan = true }
        )
        return try await reflectAndRetry(reflector, call: call, initial: outcome, context: context)
    }

    /// 执行一次工具调用（与取消竞速）。
    private func invoke(_ call: LlmToolCall, cancel: AgentCancel?) async throws -> ToolResult {
        let toolCall = ToolCall(
            name: call.name,
            callId: call.id,
            arguments: parseToolArguments(call.arguments)
        )
        guard let cancel else {
            return await tools.call(toolCall)
        }
        return try await cancel.race { [tools] in
            await tools.call(toolCall)
        }
    }

    /// 调一次模型：需要实时透传时走流式端点，否则非流式 chat（行为与纯 chat 一致）。
    private func callModel(messages: [LlmMessage], cancel: AgentCancel?) async throws -> LlmResult {
        let request = LlmRequest(messages: messages, tools: tools.describe())
        let work: @ContextTreeActor () async throws -> LlmResult = { [llm, onStream = config.onStream] in
            if let onStream {
                return try await streamChatResult(llm, request, onEvent: onStream)
            }
            return try await llm.chat(request)
        }
        guard let cancel else { return try await work() }
        return try await cancel.race(work)
    }

    /// 收口：观察口埋点、消息序列补最终回复、写会话事件、返回结局。
    private func finish(state: TurnState, reply: String, userInput: String) async throws -> AgentTurn {
        config.onEvent?("agent.finished", [
            "replyLength": .int(Int64(reply.count)),
            "steps": .int(Int64(state.steps.count)),
        ])
        var fullMessages = state.messages
        fullMessages.append(LlmMessage("assistant", reply))
        try config.session?.append(SessionEventKind.assistantMessage, data: .object([
            "text": .string(reply),
        ]))
        if let memory = config.memory, !reply.isEmpty {
            try await memory.remember("用户：\(userInput)\n助手：\(reply)", tags: ["conversation"])
        }
        return AgentTurn(reply: reply, steps: state.steps, messages: fullMessages, usage: state.usages)
    }

    /// system 消息 + 历史窗口的消息序列。
    private func initialMessages(_ userInput: String) -> [LlmMessage] {
        var system = LlmMessage("system", systemText(userInput))
        system.cacheable = true
        return [system] + deriveAgentMessages(recentAgentEvents(config.session, historyStart: historyStart))
    }

    private func assistantMessage(_ result: LlmResult) -> LlmMessage {
        var message = LlmMessage("assistant", result.content)
        message.toolCalls = result.toolCalls
        return message
    }

    private func compactIfConfigured() async throws {
        guard let session = config.session, let compactor = config.compactor else { return }
        historyStart = try await compactSession(
            session: session,
            compactor: compactor,
            llm: llm,
            historyStart: historyStart
        )
    }

    private func appendUserEvent(_ session: Session?, input: String, images: [LlmImage]) throws {
        guard let session else { return }
        var data: [String: JSONValue] = ["text": .string(input)]
        if !images.isEmpty {
            data["images"] = .array(imagesToJson(images))
        }
        try session.append(SessionEventKind.userMessage, data: .object(data))
    }

    private func appendAssistantEvent(_ session: Session?, result: LlmResult) throws {
        guard let session else { return }
        try session.append(SessionEventKind.assistantMessage, data: .object([
            "text": .string(result.content),
            "reasoning": .string(result.reasoning),
            "toolCalls": .array(toolCallsToJson(result.toolCalls)),
        ]))
    }

    /// 预置路径的 assistant 事件：只有 text（空串）与 toolCalls（无 reasoning 键，
    /// 与模型下发路径的口径差异对齐 Dart `_runPrepared`）。
    private func appendPreparedAssistantEvent(_ calls: [LlmToolCall]) throws {
        guard let session = config.session else { return }
        try session.append(SessionEventKind.assistantMessage, data: .object([
            "text": .string(""),
            "toolCalls": .array(toolCallsToJson(calls)),
        ]))
    }

    private func appendToolResultEvent(_ session: Session?, call: LlmToolCall, outcome: ToolResult) throws {
        guard let session else { return }
        try session.append(SessionEventKind.toolResult, data: .object([
            "callId": .string(call.id),
            "name": .string(call.name),
            "content": .string(outcome.content),
            "isError": .bool(outcome.failed),
        ]))
    }

    private func systemText(_ userInput: String) -> String {
        var input = SystemTextInput(userInput: userInput)
        input.defaultSystemPrompt = config.systemPrompt == nil ? config.defaultSystemPrompt : nil
        input.systemPrompt = config.systemPrompt
        input.compactor = config.compactor
        input.session = config.session
        input.memory = config.memory
        input.memoryLimit = config.memoryLimit
        return buildSystemText(input)
    }
}
