import Foundation
import SwiftusCore

/// 轮次级取消：打断在飞轮次（barge-in / 退出），让 AgentLoop.run 尽快收手。
///
/// Swift 同样不强杀在途任务：取消是**竞速停止等待**——模型/工具的底层工作可能
/// 仍在后台跑完，但其结果被丢弃，调用方立即可开始新一轮（对齐 Dart AgentCancel）。
@ContextTreeActor
public final class AgentCancel {
    /// 是否已取消。
    public private(set) var cancelled = false

    private var handlers: [UUID: @ContextTreeActor () -> Void] = [:]

    public init() {}

    /// 发出取消信号（幂等）。
    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        let pending = handlers
        handlers.removeAll()
        for handler in pending.values {
            handler()
        }
    }

    /// 与取消信号竞速：取消后以 AgentCancelled 结束，迟到结果被完成守卫丢弃。
    public func race<T: Sendable>(
        _ operation: @escaping @ContextTreeActor () async throws -> T
    ) async throws -> T {
        guard !cancelled else { throw AgentCancelled() }
        var complete: (@ContextTreeActor (Result<T, any Error>) -> Void)!
        let token = UUID()
        handlers[token] = { [weak self] in
            self?.handlers.removeValue(forKey: token)
            complete(.failure(AgentCancelled()))
        }
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            complete = { [weak self] (outcome: Result<T, any Error>) in
                guard !finished else { return }
                finished = true
                self?.handlers.removeValue(forKey: token)
                continuation.resume(with: outcome)
            }
            Task {
                do {
                    complete(.success(try await operation()))
                } catch {
                    complete(.failure(error))
                }
            }
        }
    }
}
