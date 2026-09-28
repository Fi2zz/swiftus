import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 模型请求事件类型（规格 S4 §6.1）。
///
/// Session Log 的**派生事件**（非模型可见）：记录真正发给模型的消息与工具表，
/// 用于「模型可见即可从日志重建」的不变式校验。
public let kLlmRequestEvent = "llm/request"

/// 模型响应事件类型（Session Log 的派生事件）。
public let kLlmResponseEvent = "llm/response"

/// 工具调用事件类型（Session Log 的派生事件，早于工具执行）。
public let kToolCallEvent = "tool/call"

/// 一次工具调用在循环中的步骤记录。
public struct AgentStep: Sendable {
    /// 模型请求的调用。
    public let call: LlmToolCall
    /// 工具执行结局。
    public let result: ToolResult

    public init(call: LlmToolCall, result: ToolResult) {
        self.call = call
        self.result = result
    }
}

/// 一轮 Agent 循环的结局。
public struct AgentTurn: Sendable {
    /// 最终文本回复。
    public let reply: String
    /// 本轮内的工具调用步骤。
    public let steps: [AgentStep]
    /// 本轮结束时的完整消息序列。
    public let messages: [LlmMessage]
    /// 本轮每次模型调用的用量（原样收集，按调用顺序）。
    public let usage: [[String: JSONValue]]

    public init(
        reply: String,
        steps: [AgentStep],
        messages: [LlmMessage],
        usage: [[String: JSONValue]] = []
    ) {
        self.reply = reply
        self.steps = steps
        self.messages = messages
        self.usage = usage
    }
}

/// Agent Loop 错误。
public enum AgentLoopError: Error, Equatable {
    /// 会话在循环中被关闭，循环中止。
    case sessionClosed(String)
}

/// 轮次被取消：由 AgentLoop.run 上抛，调用方据此静默收尾（不产回复）。
public struct AgentCancelled: Error, Equatable, CustomStringConvertible {
    public init() {}

    public var description: String {
        "轮次已被取消"
    }
}
