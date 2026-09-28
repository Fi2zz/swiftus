import Foundation
import SwiftusCompaction
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// Agent Loop 的事件派生与上下文装配（规格 S4 §6）：把会话事件还原为模型消息、
/// 压缩、组装 system。派生事件（`llm/request` 等）不是消息事件，不会被还原。

/// 把会话事件日志还原为模型消息序列（只识别三类消息事件，其余忽略）。
public func deriveAgentMessages(_ events: [SessionEvent]) -> [LlmMessage] {
    var messages: [LlmMessage] = []
    for event in events {
        if let message = deriveMessage(event) {
            messages.append(message)
        }
    }
    return messages
}

private func deriveMessage(_ event: SessionEvent) -> LlmMessage? {
    guard case let .object(data) = event.data else { return nil }
    if event.type == SessionEventKind.userMessage {
        var message = LlmMessage("user", stringOrEmpty(data["text"]))
        message.images = imagesFromJson(data["images"])
        return message
    }
    if event.type == SessionEventKind.assistantMessage {
        var message = LlmMessage("assistant", stringOrEmpty(data["text"]))
        message.toolCalls = toolCallsFromJson(data["toolCalls"])
        return message
    }
    if event.type == SessionEventKind.toolResult {
        return .toolResult(stringOrEmpty(data["callId"]), stringOrEmpty(data["content"]))
    }
    return nil
}

private func stringOrEmpty(_ value: JSONValue?) -> String {
    value?.stringValue ?? ""
}

/// 把事件里的 `images` 负载还原为 LlmImage 列表。
public func imagesFromJson(_ raw: JSONValue?) -> [LlmImage] {
    guard case let .array(items) = raw else { return [] }
    return items.compactMap { item in
        guard case let .object(object) = item,
              case let .string(mime) = object["mimeType"],
              case let .string(data) = object["base64Data"] else {
            return nil
        }
        return LlmImage(mimeType: mime, base64Data: data)
    }
}

/// 把 LlmImage 列表序列化为事件负载。
public func imagesToJson(_ images: [LlmImage]) -> [JSONValue] {
    images.map { image in
        .object([
            "mimeType": .string(image.mimeType),
            "base64Data": .string(image.base64Data),
        ])
    }
}

/// 把事件里的 `toolCalls` 负载还原为 LlmToolCall 列表。
public func toolCallsFromJson(_ raw: JSONValue?) -> [LlmToolCall] {
    guard case let .array(items) = raw else { return [] }
    return items.compactMap { item in
        guard case let .object(object) = item,
              case let .string(name) = object["name"] else {
            return nil
        }
        return LlmToolCall(
            id: object["id"]?.stringValue ?? "",
            name: name,
            arguments: object["arguments"]?.stringValue ?? "{}"
        )
    }
}

/// 把 LlmToolCall 列表序列化为事件负载。
public func toolCallsToJson(_ calls: [LlmToolCall]) -> [JSONValue] {
    calls.map { call in
        .object([
            "id": .string(call.id),
            "name": .string(call.name),
            "arguments": .string(call.arguments),
        ])
    }
}

/// 解析工具调用的原始 JSON 参数串；非法或非对象时返回空表
///（交给工具参数校验按缺失必填处理）。
public func parseToolArguments(_ raw: String) -> [String: JSONValue] {
    guard let data = raw.data(using: .utf8),
          case let .object(object) = try? JSONValue.parse(data) else {
        return [:]
    }
    return object
}

/// 压缩会话时发给模型的指令前缀（规格 S4 §6.2：不变式校验借此识别并跳过摘要请求）。
public let kCompactionSummaryPrompt = "请把下面这段对话压缩成简洁的中文要点（保留事实、结论与未完成事项）："

/// 用模型把一组会话事件压缩为要点摘要；previous 是上一版摘要。
public func summarizeEvents(
    _ llm: any LlmProvider,
    _ events: [SessionEvent],
    previous: String
) async throws -> CompactionSummary {
    var buffer = ""
    if !previous.isEmpty {
        buffer += "已有摘要：\n\(previous)\n\n"
    }
    buffer += kCompactionSummaryPrompt + "\n"
    for message in deriveAgentMessages(events) {
        buffer += "\(message.role): \(message.content)\n"
    }
    let result = try await llm.chat(LlmRequest(messages: [LlmMessage("user", buffer)]))
    return CompactionSummary(
        result.content.trimmingCharacters(in: .whitespacesAndNewlines),
        provider: result.provider,
        model: result.model
    )
}

/// 会话关闭时抛错以中止循环。
@ContextTreeActor
public func ensureSessionOpen(_ session: Session?) throws {
    if let session, session.closed {
        throw AgentLoopError.sessionClosed(session.id)
    }
}

/// 会话事件的历史窗口（从 historyStart 起）。
@ContextTreeActor
public func recentAgentEvents(_ session: Session?, historyStart: Int) -> [SessionEvent] {
    guard let session else { return [] }
    let events = session.events
    return historyStart <= 0 ? events : Array(events.dropFirst(historyStart))
}

/// 按预算压缩会话；返回历史窗口的起点（事件下标）。
///
/// 折叠掉的是日志开头的一段，因此窗口起点就是折叠条数（安全切点可能比预算
/// 切点更靠前，不能再用 keepRecent 反推）。
@ContextTreeActor
public func compactSession(
    session: Session?,
    compactor: (any CompactionEngine)?,
    llm: any LlmProvider,
    historyStart: Int
) async throws -> Int {
    guard let compactor, let session else { return historyStart }
    let result = try await compactor.compactIfNeeded(session) { events, previous in
        try await summarizeEvents(llm, events, previous: previous)
    }
    return result?.compacted ?? historyStart
}

/// system 组装的输入（参数封装）。
public struct SystemTextInput {
    /// 用户输入（预留给记忆召回等动态段；当前刀未接线）。
    public var userInput: String
    /// 未提供 systemPrompt 时的兜底人设。
    public var defaultSystemPrompt: String?
    /// system prompt 注册表。
    public var systemPrompt: SystemPrompt?
    /// 历史压缩器（提供摘要段）。
    public var compactor: (any CompactionEngine)?
    /// 绑定会话。
    public var session: Session?

    public init(userInput: String) {
        self.userInput = userInput
    }
}

/// 组装 system 文本（规格 S4 增补刀范围：prompt 段与动态上下文 + 历史摘要；
/// 计划段与相关记忆随后续刀接入）。
@ContextTreeActor
public func buildSystemText(_ input: SystemTextInput) -> String {
    var buffer = promptBlock(systemPrompt: input.systemPrompt, defaultSystemPrompt: input.defaultSystemPrompt)
    if let session = input.session,
       let summary = input.compactor?.summaryOf(session.id),
       !summary.isEmpty {
        buffer += "\n\n[历史摘要]\n\(summary)"
    }
    return buffer
}

/// prompt 部分：prompt 段 + 动态上下文（上下文为空时不占位）。
@ContextTreeActor
private func promptBlock(systemPrompt: SystemPrompt?, defaultSystemPrompt: String?) -> String {
    guard let systemPrompt else { return defaultSystemPrompt ?? "" }
    let assembly = systemPrompt.assemble()
    let rendered = systemPrompt.render(assembly)
    let contexts = systemPrompt.renderContexts(assembly)
    return contexts.isEmpty ? rendered : "\(rendered)\n\n\(contexts)"
}
