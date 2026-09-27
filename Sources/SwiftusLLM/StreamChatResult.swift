import SwiftusCore

/// 以流式方式调用 provider，把增量累积成一次 LlmResult（规格 S10 §5）。
///
/// 正文、思考与工具调用都从流式事件累积——实际 API 请求始终走流式端点，
/// 思考过程不会丢失。onEvent 把每个流式事件透传给宿主（实时渲染），可为空。
@ContextTreeActor
public func streamChatResult(
    _ provider: any LlmProvider,
    _ request: LlmRequest,
    onEvent: (@ContextTreeActor (LlmStreamEvent) -> Void)? = nil
) async throws -> LlmResult {
    var text = ""
    var reasoning = ""
    var done = LlmStreamDone()
    var sawEvent = false
    for try await event in provider.chatStream(request) {
        sawEvent = true
        onEvent?(event)
        switch event {
        case let .textDelta(delta):
            text += delta
        case let .reasoningDelta(delta):
            reasoning += delta
        case let .done(terminal):
            done = terminal
        }
    }
    // provider 的 chatStream 是空实现（如只实现 chat 的测试替身）：回退非流式调用。
    guard sawEvent else {
        return try await provider.chat(request)
    }
    var result = LlmResult(content: text, provider: provider.name, model: done.model)
    result.usage = done.usage
    result.toolCalls = done.toolCalls
    result.reasoning = reasoning
    return result
}
