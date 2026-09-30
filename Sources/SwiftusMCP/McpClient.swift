import Foundation
import SwiftusCore
import SwiftusFoundation

/// 一台 MCP server 的会话客户端（规格 S11 §6）。
///
/// 请求与响应按自增 int id 关联（见 `McpPendingCalls`），乱序响应也能对上号；
/// 每个请求带超时，超时以 `McpException`（`timeout`）收场。传输出错或结束时所有
/// 待办以 `disconnected` 失败、断连回调触发一次、`ready` 置假——上层据此注销
/// 该 server 的工具。
///
/// 本包不含遥测依赖：断连只通过 `diagnostics` 与 `onDisconnect` 两条通道表达。
@ContextTreeActor
public final class McpClient {
    /// `tools/list` 的翻页上限；防服务端异常导致死循环。
    public static let maxPages = 20

    private let transport: any McpTransport
    private let pending: McpPendingCalls
    private var listener: Task<Void, Never>?
    private var diagnosticTokens: [Int] = []
    private var serverInfoValue: McpServerInfo?
    private var nextId = 1
    private var readyFlag = false
    private var closedFlag = false
    private var breakReported = false

    /// 断连回调（传输结束或出错时触发**一次**）。
    public var onDisconnect: (@ContextTreeActor (String) -> Void)?

    /// server 名：工具名前缀与日志归因都用它。
    public let serverName: String

    /// 单次请求超时；零表示不限时。
    public let timeout: Duration

    public init(
        transport: any McpTransport,
        serverName: String,
        timeout: Duration = .seconds(30),
        driver: any TimerDriver = SystemTimerDriver()
    ) {
        self.transport = transport
        self.serverName = serverName
        self.timeout = timeout
        pending = McpPendingCalls(serverName: serverName, timeout: timeout, driver: driver)
    }

    /// 握手结果；`initialize` 之前为 nil。
    public var serverInfo: McpServerInfo? { serverInfoValue }

    /// 握手是否完成且连接仍活着。
    public var ready: Bool { readyFlag }

    /// 已产生的诊断（stderr、坏行、状态变化）。
    public var diagnostics: [String] { transportDiagnostics }

    private var transportDiagnostics: [String] = []

    /// 握手：`initialize` 请求 + `notifications/initialized` 通知。
    ///
    /// 服务端回的协议版本与本客户端声明不同也照收，只记录不拒绝。
    @discardableResult
    public func initialize() async throws -> McpServerInfo {
        listen()
        try await transport.connect()
        let response = try await request("initialize", [
            "protocolVersion": .string(kMcpProtocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("swiftus"),
                "version": .string(kSwiftusClientVersion),
            ]),
        ])
        let info = McpServerInfo(json: try result(of: response))
        serverInfoValue = info
        readyFlag = true
        try await transport.send(.notification(method: "notifications/initialized"))
        return info
    }

    /// 列出全部工具：按 `nextCursor` 翻页，直到服务端不再给游标。
    ///
    /// 超过 `maxPages` 页抛 `McpException`（`too-many-pages`）。
    public func listTools() async throws -> [McpTool] {
        var tools: [McpTool] = []
        var cursor: String?
        for _ in 0..<Self.maxPages {
            let params: [String: JSONValue]? = cursor.map { ["cursor": .string($0)] }
            let page = try result(of: try await request("tools/list", params))
            if let list = McpDecode.list(page["tools"]) {
                for item in list {
                    if let json = McpDecode.object(item) {
                        tools.append(McpTool(json: json))
                    }
                }
            }
            cursor = McpDecode.string(page["nextCursor"])
            if cursor == nil { return tools }
        }
        throw McpException(
            McpException.Codes.tooManyPages,
            "tools/list 翻页超过 \(Self.maxPages) 页仍未结束"
        )
    }

    /// 调用一个工具；失败结果由 `McpToolResult.failed` 表达，不抛异常。
    ///
    /// IRREVERSIBLE：服务端会实际执行这个工具；对非只读工具，其效果无法被撤销，
    /// 不存在「事后回滚」。调用前的风险分级与审批（`riskLevel` / Approval）是唯一防线。
    public func callTool(_ name: String, _ arguments: [String: JSONValue]) async throws -> McpToolResult {
        let response = try await request("tools/call", [
            "name": .string(name),
            "arguments": .object(arguments),
        ])
        return McpToolResult(json: try result(of: response))
    }

    /// 关闭会话：取消订阅、断开传输、把剩余待办判为失败；幂等。
    public func close() async {
        guard !closedFlag else { return }
        closedFlag = true
        readyFlag = false
        listener?.cancel()
        listener = nil
        pending.failAll(cause: "客户端已关闭", code: McpException.Codes.closed)
        await transport.disconnect()
    }

    // MARK: - 内部

    /// 挂上消息订阅（**只挂一次**）。
    ///
    /// 「先挂订阅再发第一条请求」是硬纪律：消息流是单订阅的，订阅前到达的数据由
    /// 传输缓冲，但缓冲只覆盖传输已投递的部分——不主动挂订阅就永远没人消费。
    private func listen() {
        guard listener == nil else { return }
        diagnosticTokens.append(transport.observeDiagnostics { [weak self] text in
            Task { @ContextTreeActor in self?.recordDiagnostic(text) }
        })
        let stream = transport.messages()
        listener = Task { @ContextTreeActor [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case let .message(message):
                    self.pending.complete(message)
                case let .failure(error):
                    self.breakOff(cause: "\(error)")
                case .finished:
                    self.breakOff(cause: "传输已结束")
                }
            }
            // 流结束也算一次断连收敛（若不是已被 breakOff 收掉）。
            self?.breakOff(cause: "传输已结束")
        }
    }

    private func recordDiagnostic(_ text: String) {
        transportDiagnostics.append(text)
        if transportDiagnostics.count > 64 {
            transportDiagnostics.removeFirst(transportDiagnostics.count - 64)
        }
    }

    /// 断连一次性：`breakReported` 守卫，重复的错误 / 结束事件只收敛一次。
    ///
    /// `closedFlag` 也要看：`close()` 取消监听会让消息循环自然退出，若不挡住，
    /// 「客户端已关闭」就会被抢在前面收敛成 `disconnected`（来源侧取消订阅后
    /// `onDone` 根本不会触发，因此那边没这个竞态）。
    private func breakOff(cause: String) {
        guard !breakReported, !closedFlag else { return }
        breakReported = true
        readyFlag = false
        pending.failAll(cause: cause, code: McpException.Codes.disconnected)
        onDisconnect?(cause)
    }

    /// 发一个请求并等它的响应。
    private func request(_ method: String, _ params: [String: JSONValue]?) async throws -> McpMessage {
        listen()
        let id = nextId
        nextId += 1
        let transport = self.transport
        return try await pending.register(
            id: id,
            makeMessage: { _ in McpMessage.request(id: id, method: method, params: params) },
            send: { message in try await transport.send(message) }
        )
    }

    /// 取出响应的 `result` 对象：失败响应抛 `protocol-error`，形态不对抛
    /// `malformed-result`。
    private func result(of response: McpMessage) throws -> [String: JSONValue] {
        if let error = response.error {
            throw McpException(
                McpException.Codes.protocolError,
                "\(error.code): \(error.message)"
            )
        }
        guard let result = McpDecode.object(response.result) else {
            throw McpException(McpException.Codes.malformedResult, "响应缺少 result 对象")
        }
        return result
    }
}

/// 本客户端在 `clientInfo` 里自报的版本。
let kSwiftusClientVersion = "0.1.0"
