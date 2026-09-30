import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusMCP

/// 可手动推进的时间缝（规格 S11 §6 的超时纪律）。
///
/// 与 S9 / S19 的同名件各拷一份到自己的测试 target：跨 target 共享测试工具会
/// 把测试 target 的依赖图连起来，本仓一律「测试替身不共享」。
final class McpManualTimerDriver: TimerDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Duration = .zero
    private var waiters: [Waiter] = []
    private var nextId = 1

    /// 推进时间并叫醒到点的等待者。
    ///
    /// 到点判据是「累计 elapsed ≥ 登记时的 start + interval」，于是多次推进可以
    /// 累积到某个较长的等待（不会像「每次推进都只按本次 interval 比」那样漏叫）。
    func advance(_ interval: Duration) {
        lock.lock()
        elapsed += interval
        let due = waiters.filter { elapsed - $0.start >= $0.interval }
        waiters.removeAll { waiter in due.contains { $0.id == waiter.id } }
        lock.unlock()
        for waiter in due {
            waiter.continuation.resume()
        }
    }

    func wait(_ interval: Duration) async throws {
        guard interval > .zero else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if elapsed >= interval {
                lock.unlock()
                continuation.resume()
                return
            }
            let id = nextId
            nextId += 1
            waiters.append(Waiter(id: id, start: elapsed, interval: interval, continuation: continuation))
            lock.unlock()
        }
    }

    func now() -> Duration {
        lock.lock(); defer { lock.unlock() }
        return elapsed
    }

    private struct Waiter {
        let id: Int
        let start: Duration
        let interval: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }
}

/// 按方法自动应答的进程内假传输：记录发出的消息、模拟断连与畸形页
/// （与导出器 `_ScriptedTransport` 同形，输入同在 fixture 里）。
@ContextTreeActor
final class ScriptedMcpTransport: McpTransport {
    let sink = ScriptedMcpSink()
    let diagnostics = McpDiagnostics()

    /// `initialize` 的 `result`。
    var initialize: [String: JSONValue] = ["protocolVersion": .string(kMcpProtocolVersion)]
    /// 非空时 `initialize` 回失败响应。
    var initializeError: [String: JSONValue]?
    /// 非空时 `connect` 抛它（模拟连不上的服务端）。
    var connectError: McpException?
    /// `tools/list` 的分页 `result`（按序消费；非对象形态直接放这里）。
    var pages: [JSONValue?] = []
    /// `tools/call` 的 `result`。
    var callResult: [String: JSONValue] = [:]
    /// 这些方法**不回应**（模拟哑巴服务端 / 断连前在账请求）。
    var silentMethods: Set<String> = []

    private(set) var sentLabels: [String] = []
    private var page = 0
    private var closedFlag = true

    init() {}

    var connected: Bool { !closedFlag }

    func connect() async throws {
        if let connectError { throw connectError }
        if !closedFlag { return }
        closedFlag = false
    }

    func disconnect() async {
        closedFlag = true
    }

    func messages() -> AsyncStream<McpTransportEvent> {
        sink.stream()
    }

    @discardableResult
    func observeDiagnostics(_ body: @escaping @Sendable (String) -> Void) -> Int {
        diagnostics.observe(body)
    }

    func send(_ message: McpMessage) async throws {
        guard let method = message.method else { return }
        sentLabels.append(method)
        if message.isNotification { return }
        guard let id = message.id, !silentMethods.contains(method) else { return }
        sink.emit(McpMessage(json: reply(method: method, id: id)))
    }

    /// 注入连接级故障（模拟子进程退出 / SSE 结束）。
    func fail(_ error: any Error) {
        sink.emitFailure(error)
        sink.finish()
    }

    private func reply(method: String, id: JSONValue) -> [String: JSONValue] {
        switch method {
        case "initialize":
            if let initializeError {
                return ["jsonrpc": .string("2.0"), "id": id, "error": .object(initializeError)]
            }
            return ["jsonrpc": .string("2.0"), "id": id, "result": .object(initialize)]
        case "tools/call":
            return ["jsonrpc": .string("2.0"), "id": id, "result": .object(callResult)]
        case "tools/list":
            // 页用尽后重复最后一页：游标一直在 → 触发翻页上限。
            let value: JSONValue
            if page < pages.count {
                value = pages[page] ?? .null
            } else if let last = pages.last {
                value = last ?? .null
            } else {
                value = .object(["tools": .array([])])
            }
            page += 1
            return ["jsonrpc": .string("2.0"), "id": id, "result": value]
        default:
            return ["jsonrpc": .string("2.0"), "id": id, "result": .object([:])]
        }
    }
}

/// 测试用消息接收端（复用生产实现的缓冲语义，但可直连注入）。
@ContextTreeActor
final class ScriptedMcpSink {
    private let sink = McpMessageSink()

    func stream() -> AsyncStream<McpTransportEvent> { sink.stream() }
    func emit(_ message: McpMessage) { sink.emit(message) }
    func emitFailure(_ error: any Error) { sink.emitFailure(error) }
    func finish() { sink.finish() }
}
