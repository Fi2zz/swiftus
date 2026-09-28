import SwiftusCore

/// 大模型提供商抽象（规格 S10）。
@ContextTreeActor
public protocol LlmProvider: AnyObject, Sendable {
    var name: String { get }

    /// 非流式聊天补全；实际实现可走流式端点累积（见 streamChatResult）。
    func chat(_ request: LlmRequest) async throws -> LlmResult

    /// 流式聊天补全；工具调用在 done 事件一次性给出。
    func chatStream(_ request: LlmRequest) -> AsyncThrowingStream<LlmStreamEvent, Error>

    /// 释放底层资源（如 HTTP 客户端）；默认无操作。
    func close()
}

extension LlmProvider {
    public func close() {}
}

/// 'llm' 服务键。
extension ServiceKey where Service == any LlmProvider {
    public static let llm = ServiceKey<any LlmProvider>("llm")
}

/// 将 FallbackLlm 作为 'llm' 服务提供到上下文（规格 S10 §12）；close 随上下文释放登记。
@ContextTreeActor
@discardableResult
public func provideLlm(_ ctx: Context, llm: FallbackLlm) throws -> Disposer {
    let disposer = try ctx.provide(.llm, llm)
    ctx.onDispose { llm.close() }
    return disposer
}
