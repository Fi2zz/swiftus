import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 记录 `llm/request` / `llm/response` 派生事件的 LlmProvider 装饰器（规格 S4 §6.3）。
///
/// 装饰器不改动请求本身，只在两侧记录，因此对既有 Provider 与测试完全透明。
@ContextTreeActor
public final class SessionLogLlmProvider: LlmProvider {
    /// 被包装的提供方。
    public let inner: any LlmProvider
    /// 目标记录器。
    public let recorder: SessionLogRecorder

    public init(_ inner: any LlmProvider, recorder: SessionLogRecorder) {
        self.inner = inner
        self.recorder = recorder
    }

    public var name: String {
        inner.name
    }

    public func chat(_ request: LlmRequest) async throws -> LlmResult {
        try await recordRequest(request)
        try await assertModelVisible()
        let result = try await inner.chat(request)
        try await recorder.record(kLlmResponseEvent, data: responseData(result))
        return result
    }

    public func chatStream(_ request: LlmRequest) -> AsyncThrowingStream<LlmStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await recordRequest(request)
                    try await assertModelVisible()
                    var text = ""
                    var terminal: LlmStreamDone?
                    for try await event in inner.chatStream(request) {
                        if case let .textDelta(delta) = event { text += delta }
                        if case let .done(done) = event { terminal = done }
                        continuation.yield(event)
                    }
                    try await recordStreamResponse(text: text, terminal: terminal)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func close() {
        inner.close()
    }

    /// 发送前记录请求：真正发给模型的消息与工具表（规格 S4 §6.1）。
    private func recordRequest(_ request: LlmRequest) async throws {
        var data: [String: JSONValue] = [
            "provider": .string(inner.name),
            "messages": .array(request.messages.map(\.chatItem)),
        ]
        if let tools = request.tools, !tools.isEmpty {
            data["tools"] = .array(tools)
        }
        try await recorder.record(kLlmRequestEvent, data: .object(data))
    }

    /// 开发模式断言：发送前确认这条请求能从日志重建（生产默认关闭）。
    /// 只校验当前这条请求对日志的一致性（压缩摘要请求会被识别并跳过）。
    private func assertModelVisible() async throws {
        guard recorder.strictModelVisible, let sessionId = recorder.sessionId else { return }
        let events = try await recorder.log.read(sessionId)
        try assertModelVisibleInvariant(events)
    }

    private func responseData(_ result: LlmResult) -> JSONValue {
        .object([
            "provider": .string(result.provider),
            "model": .string(result.model),
            "content": .string(result.content),
            "toolCalls": .array(toolCallsToJson(result.toolCalls)),
            "usage": .object(result.usage),
        ])
    }

    /// 流式响应：content 为累计文本，provider/model 取提供方名（对齐 Dart 用 inner.name），
    /// 附 finishReason。
    private func recordStreamResponse(text: String, terminal: LlmStreamDone?) async throws {
        var result = LlmResult(content: text, provider: inner.name, model: inner.name)
        result.toolCalls = terminal?.toolCalls ?? []
        result.usage = terminal?.usage ?? [:]
        var fields = responseData(result).objectValue ?? [:]
        if let finishReason = terminal?.finishReason {
            fields["finishReason"] = .string(finishReason)
        }
        try await recorder.record(kLlmResponseEvent, data: .object(fields))
    }
}
