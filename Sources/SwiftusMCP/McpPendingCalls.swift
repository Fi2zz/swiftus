import Foundation
import SwiftusCore
import SwiftusFoundation

/// `McpClient` 的待办请求簿（规格 S11 §6）。
///
/// 每个请求按自增 id 入账并附一个超时计时器；响应到达即出账并完成对应的
/// continuation。断连或关闭时 `failAll` 把所有在账请求一次性判失败，等待方不会
/// 永久悬挂。
@ContextTreeActor
final class McpPendingCalls {
    private let serverName: String
    private let timeout: Duration
    private let driver: any TimerDriver
    private var pending: [Int: CheckedContinuation<McpMessage, any Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]

    init(serverName: String, timeout: Duration, driver: any TimerDriver) {
        self.serverName = serverName
        self.timeout = timeout
        self.driver = driver
    }

    /// 在账请求数。
    var length: Int { pending.count }

    /// 登记请求 `id` 并发出；发送异常收敛到本次请求上（不影响其他在账请求）。
    ///
    /// 先挂 continuation 再发送：响应可能在 `send` 返回前就到了。
    func register(
        id: Int,
        makeMessage: @escaping @ContextTreeActor (Int) -> McpMessage,
        send: @escaping @ContextTreeActor (McpMessage) async throws -> Void
    ) async throws -> McpMessage {
        let driver = driver
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            armTimeout(id: id, timeout: timeout, driver: driver)
            Task {
                do {
                    try await send(makeMessage(id))
                } catch {
                    fail(id: id, error: error)
                }
            }
        }
    }

    /// 按 id 关联一条响应；无关消息（通知、服务端主动请求）忽略。
    func complete(_ message: McpMessage) {
        guard case let .int(raw)? = message.id else { return }
        let id = Int(raw)
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timers[id]?.cancel()
        timers[id] = nil
        continuation.resume(returning: message)
    }

    /// 把 `id` 的在账请求判为失败；不在账（已超时或已完成）时无动作。
    func fail(id: Int, error: any Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timers[id]?.cancel()
        timers[id] = nil
        continuation.resume(throwing: error)
    }

    /// 把所有在账请求判为失败，`cause` 写进消息、`code` 作为错误码。
    func failAll(cause: String, code: String) {
        let error = McpException(
            code,
            "与服务端 \"\(serverName)\" 的连接中断：\(cause)"
        )
        for id in pending.keys.sorted() {
            fail(id: id, error: error)
        }
    }

    private func armTimeout(id: Int, timeout: Duration, driver: any TimerDriver) {
        // 零超时表示不限时：不计时。
        guard timeout > .zero else { return }
        let millis = Int(timeout.components.seconds) * 1000
            + Int(timeout.components.attoseconds / 1_000_000_000_000_000)
        timers[id] = Task { [weak self] in
            do {
                try await driver.wait(timeout)
            } catch {
                return // 等待被取消（close / 上下文释放）→ 不判超时
            }
            guard let self, !Task.isCancelled else { return }
            self.fail(id: id, error: McpException(
                McpException.Codes.timeout,
                "请求 \(id) 在 \(millis)ms 内没有响应"
            ))
        }
    }
}
