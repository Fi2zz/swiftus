import Foundation
import SwiftusCore

/// 一条 MCP 连接的传输层（规格 S11 §5）。
///
/// 实现负责把 `McpMessage` 搬到对端（子进程管道、HTTP POST 或 SSE 长连接），
/// 并把对端来的数据还原成消息。传输层的错误有两种归宿：
///
/// * `messages` 上的连接级故障（进程退出、SSE 结束）——上层据此判定断连；
/// * `send` 抛错——单次发送失败（HTTP 非 200），只影响这一次请求。
///
/// **消息流是单订阅的**（与来源一致）：`AsyncStream` 天然单消费者。
@ContextTreeActor
public protocol McpTransport: AnyObject, Sendable {
    /// 建立连接；已连接时重复调用应无害。
    func connect() async throws

    /// 断开连接并释放资源；幂等。
    func disconnect() async

    /// 自对端流入的消息；**单订阅**，连接级故障以 `McpTransport.failure` 形态送达。
    func messages() -> AsyncStream<McpTransportEvent>

    /// 登记诊断观察者（stderr、坏行、状态变化）；返回注销令牌。
    @discardableResult
    func observeDiagnostics(_ body: @escaping @Sendable (String) -> Void) -> Int

    /// 发送一条消息。
    ///
    /// 单次发送失败抛 `McpException`，不污染 `messages`。
    func send(_ message: McpMessage) async throws
}

/// 消息流的元素：正常消息 / 连接级故障。
///
/// 故障是**值**而不是流的 error：Swift 的 `AsyncStream` 一旦 `finish` 就无法再
/// 投递，而断连之后上层仍要能读到「流结束了」这个事实并做一次收敛（S11 §6）。
public enum McpTransportEvent: Sendable {
    case message(McpMessage)
    /// 连接级故障（进程退出、SSE 结束、网络中断）。
    case failure(any Error)
    /// 对端关闭消息流。
    case finished
}
