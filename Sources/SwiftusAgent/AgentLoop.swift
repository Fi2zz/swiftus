import Foundation
import SwiftusCompaction
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// Agent Loop（规格 S4 增补刀：核心闭环）——调模型、跑工具、回填结果，直到收口。
/// 组装 system（SystemPrompt + 摘要）→ 调模型（带 ToolRegistry.describe）→
/// 执行工具并回填 → 收口。planning / 反思 / 路由 / 记忆 / goal 续行随后续刀接入。
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

    /// 模型接入。
    public let llm: any LlmProvider
    /// 工具注册表。
    public let tools: ToolRegistry
    /// 运行配置。
    public let config: Config

    private var historyStart = 0

    public init(llm: any LlmProvider, tools: ToolRegistry, config: Config = Config()) {
        self.llm = llm
        self.tools = tools
        self.config = config
    }

    /// 绑定的会话。
    public var session: Session? {
        config.session
    }

    /// 跑一轮：从 userInput 到最终文本回复。
    ///
    /// cancel 非空时，模型调用与工具执行都与其竞速；取消后本方法以
    /// AgentCancelled 结束（结果丢弃，调用方可立即开始新一轮）。
    /// images 非空时随用户消息发给模型并写入会话事件（多模态输入）。
    @discardableResult
    public func run(
        _ userInput: String,
        cancel: AgentCancel? = nil,
        images: [LlmImage] = []
    ) async throws -> AgentTurn {
        let session = config.session
        try ensureSessionOpen(session)
        try appendUserEvent(session, input: userInput, images: images)
        if let session, let compactor = config.compactor {
            historyStart = try await compactSession(
                session: session,
                compactor: compactor,
                llm: llm,
                historyStart: historyStart
            )
        }
        var messages = initialMessages(userInput)
        var steps: [AgentStep] = []
        var usages: [[String: JSONValue]] = []
        for step in 0..<config.maxSteps {
            try ensureSessionOpen(session)
            let result = try await callModel(messages: messages, cancel: cancel)
            usages.append(result.usage)
            config.onEvent?("agent.round", [
                "step": .int(Int64(step)),
                "toolCalls": .int(Int64(result.toolCalls.count)),
                "contentLength": .int(Int64(result.content.count)),
            ])
            if result.toolCalls.isEmpty {
                let reply = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return try await finish(messages: messages, steps: steps, usages: usages, reply: reply)
            }
            messages.append(assistantMessage(result))
            try appendAssistantEvent(session, result: result)
            for call in result.toolCalls {
                let outcome = try await invoke(call, cancel: cancel)
                messages.append(.toolResult(call.id, outcome.content))
                try appendToolResultEvent(session, call: call, outcome: outcome)
                steps.append(AgentStep(call: call, result: outcome))
            }
        }
        return try await finish(
            messages: messages,
            steps: steps,
            usages: usages,
            reply: "（已达到最大步数 \(config.maxSteps)，未收口）"
        )
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
    private func finish(
        messages: [LlmMessage],
        steps: [AgentStep],
        usages: [[String: JSONValue]],
        reply: String
    ) async throws -> AgentTurn {
        config.onEvent?("agent.finished", [
            "replyLength": .int(Int64(reply.count)),
            "steps": .int(Int64(steps.count)),
        ])
        var fullMessages = messages
        fullMessages.append(LlmMessage("assistant", reply))
        try config.session?.append(SessionEventKind.assistantMessage, data: .object([
            "text": .string(reply),
        ]))
        return AgentTurn(reply: reply, steps: steps, messages: fullMessages, usage: usages)
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
        return buildSystemText(input)
    }
}
