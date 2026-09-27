import SwiftusCore
import SwiftusLLM

/// 脚本化模型：按预设响应序列应答，无需 API Key（离线 Demo 与测试的驱动器）。
///
/// 每次 chat 消费一条预设；耗尽后抛 LlmException。chatStream 是空实现——
/// 走 streamChatResult 的调用方会自动回退 chat()（规格 S10 §5 的空流回退）。
@ContextTreeActor
public final class ScriptedLlm: LlmProvider {
    public let name: String

    /// 已收到的请求（测试断言用）。
    public private(set) var requests: [LlmRequest] = []

    private var responses: [@ContextTreeActor (LlmRequest) -> LlmResult]

    public init(name: String = "scripted", responses: [@ContextTreeActor (LlmRequest) -> LlmResult]) {
        self.name = name
        self.responses = responses
    }

    public func chat(_ request: LlmRequest) async throws -> LlmResult {
        requests.append(request)
        guard !responses.isEmpty else {
            throw LlmException(name, "脚本耗尽：第 \(requests.count) 次请求没有预设响应")
        }
        return responses.removeFirst()(request)
    }

    public func chatStream(_ request: LlmRequest) -> AsyncThrowingStream<LlmStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
