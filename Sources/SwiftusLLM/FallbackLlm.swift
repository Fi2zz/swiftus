import SwiftusCore

/// 按顺序尝试多个提供商，直到有一个成功（规格 S10 §11）。
///
/// 非流式与流式都支持回退；全部失败时抛出 LlmException，消息汇总所有提供商的错误。
/// 流式回退只在**尚未产出任何事件**时生效；一旦产出过增量，中途失败直接上抛。
@ContextTreeActor
public final class FallbackLlm: LlmProvider {
    public let providers: [any LlmProvider]

    public init(_ providers: [any LlmProvider]) {
        self.providers = providers
    }

    public var name: String {
        "fallback"
    }

    public func chat(_ request: LlmRequest) async throws -> LlmResult {
        var errors: [String] = []
        for provider in providers {
            do {
                return try await provider.chat(request)
            } catch {
                errors.append(describe(error, of: provider))
            }
        }
        throw LlmException(name, aggregatedMessage(errors))
    }

    public func chatStream(_ request: LlmRequest) -> AsyncThrowingStream<LlmStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await runFallback(request, continuation: continuation) }
        }
    }

    public func close() {
        providers.forEach { $0.close() }
    }

    private func runFallback(
        _ request: LlmRequest,
        continuation: AsyncThrowingStream<LlmStreamEvent, Error>.Continuation
    ) async {
        var errors: [String] = []
        for provider in providers {
            var emitted = false
            do {
                for try await event in provider.chatStream(request) {
                    emitted = true
                    continuation.yield(event)
                }
                continuation.finish()
                return
            } catch {
                guard !emitted else {
                    continuation.finish(throwing: error)
                    return
                }
                errors.append(describe(error, of: provider))
            }
        }
        continuation.finish(throwing: LlmException(name, aggregatedMessage(errors)))
    }

    private func aggregatedMessage(_ errors: [String]) -> String {
        "所有提供商均失败：\n\(errors.joined(separator: "\n"))"
    }

    private func describe(_ error: any Error, of provider: any LlmProvider) -> String {
        if let error = error as? LlmException {
            return "\(provider.name): \(error.message)"
        }
        return "\(provider.name): \(error)"
    }
}
