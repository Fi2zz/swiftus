import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 最小 Agent 循环：「提问 → 工具调用 → 回填 → 收口」。
///
/// 这是 W1 收口的演示骨架，不是 SwiftusAgent（W2）——没有 plan / sub-agent /
/// telemetry 等产品化能力，只验证五块拼图（core / llm / prompt / tool / skill）
/// 能组成一条可运行的回路。
@ContextTreeActor
public struct MiniAgentLoop {
    public let llm: any LlmProvider
    public let tools: ToolRegistry
    public let systemPrompt: String

    public init(llm: any LlmProvider, tools: ToolRegistry, systemPrompt: String) {
        self.llm = llm
        self.tools = tools
        self.systemPrompt = systemPrompt
    }

    /// 跑到模型不再请求工具（收口）为止；超出 maxRounds 抛 MiniAgentError.roundsExhausted。
    public func run(_ userInput: String, maxRounds: Int = 8) async throws -> MiniAgentRun {
        var messages: [LlmMessage] = [
            LlmMessage("system", systemPrompt),
            LlmMessage("user", userInput),
        ]
        var steps: [MiniAgentStep] = []
        for _ in 0..<maxRounds {
            let result = try await llm.chat(LlmRequest(messages: messages, tools: tools.describe()))
            guard !result.toolCalls.isEmpty else {
                return MiniAgentRun(steps: steps, answer: result.content)
            }
            messages.append(.toolCallRequest(result.toolCalls, content: result.content))
            let step = await executeCalls(result.toolCalls, messages: &messages)
            steps.append(step)
        }
        throw MiniAgentError.roundsExhausted(maxRounds)
    }

    /// 顺序执行一轮工具调用并把结果回填进消息历史。
    private func executeCalls(
        _ calls: [LlmToolCall],
        messages: inout [LlmMessage]
    ) async -> MiniAgentStep {
        var results: [ToolResult] = []
        for call in calls {
            let outcome = await tools.call(ToolCall(
                name: call.name,
                callId: call.id,
                arguments: parseToolArguments(call.arguments)
            ))
            results.append(outcome)
            messages.append(.toolResult(call.id, outcome.content))
        }
        return MiniAgentStep(toolCalls: calls, results: results)
    }
}

/// 一轮工具调用的记录。
public struct MiniAgentStep {
    public let toolCalls: [LlmToolCall]
    public let results: [ToolResult]
}

/// 一次完整运行：各轮记录与最终回答。
public struct MiniAgentRun {
    public let steps: [MiniAgentStep]
    public let answer: String
}

/// 循环错误。
public enum MiniAgentError: Error, Equatable {
    /// 超过 maxRounds 轮模型仍在请求工具。
    case roundsExhausted(Int)
}

/// 解析工具调用的原始 JSON 参数串；非法或非对象按空对象处理（由参数校验管线报 INVALID_ARGS）。
func parseToolArguments(_ raw: String) -> [String: JSONValue] {
    guard let parsed = try? JSONValue.parse(Data(raw.utf8)),
          let object = parsed.objectValue
    else { return [:] }
    return object
}
