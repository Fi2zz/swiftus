import SwiftusCore
import SwiftusLLM

/// 脚本化 LlmProvider 测试替身:chat / chatStream 行为由 handler 驱动。
@ContextTreeActor
final class ScriptedProvider: LlmProvider {
    let name: String

    var chatHandler: (@ContextTreeActor (LlmRequest) async throws -> LlmResult)?
    var streamHandler: (@ContextTreeActor (
        LlmRequest,
        AsyncThrowingStream<LlmStreamEvent, Error>.Continuation
    ) async throws -> Void)?
    private(set) var closed = false

    init(name: String) {
        self.name = name
    }

    func chat(_ request: LlmRequest) async throws -> LlmResult {
        guard let chatHandler else {
            return LlmResult(content: "", provider: name, model: "scripted")
        }
        return try await chatHandler(request)
    }

    func chatStream(_ request: LlmRequest) -> AsyncThrowingStream<LlmStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let streamHandler else {
                    continuation.finish()
                    return
                }
                do {
                    try await streamHandler(request, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func close() {
        closed = true
    }
}
