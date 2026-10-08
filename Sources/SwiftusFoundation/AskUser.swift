import Foundation
import os
import SwiftusCore

/// 提问器端口（规格 S16 §6.1）。
public protocol AskUser: Sendable {
    /// 向用户展示 prompt，返回其输入；等待期间被 cancel 应抛 AskCancelledError。
    func ask(_ prompt: String) async throws -> String

    /// 取消所有正在进行的提问。幂等。
    func cancel()
}

/// 提问被取消时抛出。
public struct AskCancelledError: Error, Equatable, CustomStringConvertible {
    public init() {}

    public var description: String {
        "提问已取消"
    }
}

/// 基于标准输入输出的默认提问器（规格 S16 §6.1，submit 驱动）。
///
/// ask 把 prompt 写出并登记在途提问（不直接阻塞读 stdin）；由 submit 投递给
/// 最早等待者——供测试或自定义输入源（如 GUI 事件循环）驱动。
public final class CliAskUser: AskUser {
    private struct State {
        var pending: [CheckedContinuation<String, any Error>] = []
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private let writer: @Sendable (String) -> Void

    public init(writer: (@Sendable (String) -> Void)? = nil) {
        self.writer = writer ?? { print($0) }
    }

    public func ask(_ prompt: String) async throws -> String {
        writer(prompt)
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { current -> Void in
                if current.cancelled {
                    continuation.resume(throwing: AskCancelledError())
                } else {
                    current.pending.append(continuation)
                }
            }
        }
    }

    /// 将一行输入投递给最早等待中的提问。
    public func submit(_ line: String) {
        state.withLock { current -> Void in
            guard !current.pending.isEmpty else { return }
            let continuation = current.pending.removeFirst()
            continuation.resume(returning: line)
        }
    }

    /// 当前在途提问数。
    ///
    /// 供驱动侧做**有界等待**（等到 `ask` 真的登记后再 `submit`），
    /// 避免用固定 `Task.sleep` 猜时序——CI / release 负载下会踩空
    /// （AGENTS 坑 #9/#108）。
    public var pendingCount: Int {
        state.withLock { $0.pending.count }
    }

    public func cancel() {
        state.withLock { current -> Void in
            current.cancelled = true
            for continuation in current.pending {
                continuation.resume(throwing: AskCancelledError())
            }
            current.pending.removeAll()
        }
    }
}

/// 'askUser' 服务键。
extension ServiceKey where Service == any AskUser {
    public static let askUser = ServiceKey<any AskUser>("askUser")
}

/// 将 AskUser 作为 'askUser' 服务提供到上下文；随上下文释放 cancel。
@ContextTreeActor
@discardableResult
public func provideAskUser(_ ctx: Context, askUser: (any AskUser)? = nil) throws -> any AskUser {
    let resolved = askUser ?? CliAskUser()
    try ctx.provide(.askUser, resolved)
    ctx.onDispose { resolved.cancel() }
    return resolved
}
