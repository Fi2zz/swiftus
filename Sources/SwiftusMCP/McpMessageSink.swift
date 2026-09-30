import Foundation
import SwiftusCore

/// 传输层的消息接收端：单订阅 + 订阅前缓冲（规格 S11 §5）。
///
/// 行为对齐来源的 `StreamController`（非 broadcast）：
/// - **单订阅**：`stream()` 第二次调用返回**空流**（已订阅过）；
/// - **订阅前缓冲**：`AsyncStream` 的 continuation 只在订阅时才有，
///   而对端数据（子进程输出 / SSE 推送）可能先到——不缓冲就会丢消息，
///   于是「先挂订阅再发第一条请求」这条纪律一旦被违反就变成静默挂起。
@ContextTreeActor
public final class McpMessageSink {
    private var continuation: AsyncStream<McpTransportEvent>.Continuation?
    private var buffered: [McpTransportEvent] = []
    private var subscribed = false
    private var closed = false

    public init() {}

    /// 连接是否已建立且尚未断开。
    public var connected = false

    /// 取消息流（**单订阅**；重复调用返回空流）。
    public func stream() -> AsyncStream<McpTransportEvent> {
        guard !subscribed else {
            return AsyncStream { $0.finish() }
        }
        subscribed = true
        let (stream, continuation) = AsyncStream<McpTransportEvent>.makeStream()
        self.continuation = continuation
        // 订阅前缓冲的事件按序回放。
        let replay = buffered
        buffered = []
        for event in replay {
            continuation.yield(event)
        }
        if closed {
            continuation.finish()
            self.continuation = nil
        }
        return stream
    }

    /// 派发一条消息。
    public func emit(_ message: McpMessage) {
        deliver(.message(message))
    }

    /// 派发一个连接级故障（如 SSE 中断，子进程退出）。
    public func emitFailure(_ error: any Error) {
        deliver(.failure(error))
    }

    /// 记一条诊断。
    public func emitFailure(code: String, message: String) {
        emitFailure(McpException(code, message))
    }

    /// 关闭消息流（对端结束）；幂等。关闭后不再接受任何事件。
    public func finish() {
        guard !closed else { return }
        closed = true
        if let continuation {
            continuation.finish()
            self.continuation = nil
        } else {
            buffered.append(.finished)
        }
    }

    private func deliver(_ event: McpTransportEvent) {
        guard !closed else { return }
        if let continuation {
            continuation.yield(event)
        } else {
            buffered.append(event)
        }
    }
}

/// 传输层的诊断总线：多观察者 + 缓冲（规格 S11 §5）。
///
/// 诊断**不是**消息流的一部分（来源里也是两条独立的流），且允许晚到的观察者
/// 读到已产生的诊断——装配阶段挂上监听器之前，坏行就已经发生了。
@ContextTreeActor
public final class McpDiagnostics {
    private var listeners: [Int: @Sendable (String) -> Void] = [:]
    private var history: [String] = []
    private var nextToken = 1
    private let keepHistory: Bool

    public init(keepHistory: Bool = true) {
        self.keepHistory = keepHistory
    }

    /// 登记观察者；返回注销令牌。
    @discardableResult
    public func observe(_ body: @escaping @Sendable (String) -> Void) -> Int {
        let token = nextToken
        nextToken += 1
        listeners[token] = body
        return token
    }

    /// 注销观察者；返回是否确实移除了。
    @discardableResult
    public func remove(_ token: Int) -> Bool {
        listeners.removeValue(forKey: token) != nil
    }

    /// 已产生的诊断（仅保留最近 64 条，防无界增长）。
    public var recent: [String] {
        history
    }

    /// 记一条诊断（stderr、坏行、状态变化）；诊断不是错误，不打断连接。
    public func log(_ text: String) {
        if keepHistory {
            history.append(text)
            if history.count > 64 { history.removeFirst(history.count - 64) }
        }
        for body in listeners.values {
            body(text)
        }
    }

    /// 释放全部观察者。
    public func dispose() {
        listeners.removeAll()
    }
}
