import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 「模型可见即已记录」不变式（规格 S4 §6.2）：日志里每条 `llm/request` 都必须
/// 能从日志本身重建。
///
/// 目的是让 Session Log 真正可作轨迹回放：凡是进入模型的内容，都能在日志里找到
/// 出处，不存在绕过日志的上下文注入。压缩只会**缩短**发给模型的窗口（更早的内容
/// 以摘要形式进入 system prompt），因此请求是可重建消息的尾对齐后缀。

/// 检查不变式，返回全部违规描述（空数组表示通过）。
public func checkModelVisibleInvariant(_ events: [SessionEvent]) -> [String] {
    var violations: [String] = []
    for (index, event) in events.enumerated() where event.type == kLlmRequestEvent {
        guard let logged = loggedMessages(of: event) else {
            violations.append("第 \(index) 条 \(kLlmRequestEvent) 缺少 messages 负载")
            continue
        }
        let conversation = conversationPart(logged)
        if compactionRequest(conversation) { continue }
        violations.append(contentsOf: compareRequests(
            index: index,
            expected: deriveAgentMessages(Array(events[..<index])),
            logged: conversation
        ))
    }
    return violations
}

/// 断言不变式，违规时抛 ModelVisibleInvariantError（开发模式使用，生产可不启用）。
public func assertModelVisibleInvariant(_ events: [SessionEvent]) throws {
    let violations = checkModelVisibleInvariant(events)
    guard violations.isEmpty else {
        throw ModelVisibleInvariantError(violations: violations)
    }
}

/// 不变式被破坏（违规描述列表）。
public struct ModelVisibleInvariantError: Error, Equatable, CustomStringConvertible {
    public let violations: [String]

    public init(violations: [String]) {
        self.violations = violations
    }

    public var description: String {
        "模型可见即已记录不变式被破坏：\n\(violations.joined(separator: "\n"))"
    }
}

/// 尾对齐比对：请求必须是可重建消息的一个后缀，且逐条一致（规格 S4 §6.2）。
private func compareRequests(index: Int, expected: [LlmMessage], logged: [JSONValue]) -> [String] {
    let offset = expected.count - logged.count
    if offset < 0 {
        return [
            "第 \(index) 条 \(kLlmRequestEvent) 实际发出 \(logged.count) 条会话消息，日志只能重建 \(expected.count) 条"
        ]
    }
    var problems: [String] = []
    for (i, message) in logged.enumerated() {
        if expected[offset + i].chatItem != message {
            problems.append("第 \(index) 条 \(kLlmRequestEvent) 的第 \(i) 条会话消息无法从日志重建")
        }
    }
    return problems
}

/// 请求的 messages 负载；缺失或非数组为 nil。
private func loggedMessages(of event: SessionEvent) -> [JSONValue]? {
    guard case let .array(messages) = event.data?["messages"] else { return nil }
    return messages
}

/// 请求里首个非 system 消息起的部分。
private func conversationPart(_ messages: [JSONValue]) -> [JSONValue] {
    var start = 0
    while start < messages.count, role(of: messages[start]) == "system" {
        start += 1
    }
    return Array(messages[start...])
}

/// 是不是压缩摘要请求：会话部分只有一条含指令前缀的 user 消息（规格 S4 §6.2 除外项）。
private func compactionRequest(_ conversation: [JSONValue]) -> Bool {
    guard conversation.count == 1, role(of: conversation[0]) == "user" else { return false }
    return content(of: conversation[0]).contains(kCompactionSummaryPrompt)
}

private func role(of message: JSONValue) -> String? {
    message["role"]?.stringValue
}

private func content(of message: JSONValue) -> String {
    message["content"]?.stringValue ?? ""
}
