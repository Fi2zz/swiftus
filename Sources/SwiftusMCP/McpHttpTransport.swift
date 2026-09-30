import Foundation
import SwiftusCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP 系传输（`http` / `sse`）的共用实现（规格 S11 §5）。
///
/// 负责消息与诊断的收发、坏数据的降级、`URLSession` 的 POST / 长连接基础设施。
/// 子类只声明各自的连接语义与端点：`HttpTransport` 一发一收，
/// `SseTransport` 长连接 + endpoint 事件。
///
/// 一个传输实例是**一次性**的：`disconnect` 之后再 `connect` 不会重新建立
/// 可用的会话（消息 / 诊断已关闭），`connected` 也会复位为 `false`。
@ContextTreeActor
open class McpHttpTransport: McpTransport {
    /// 传输端点。
    public let url: URL
    /// 附加请求头。
    public let headers: [String: String]
    /// HTTP 客户端（注入点：测试用 `URLProtocol` 桩）。
    public let session: URLSession

    /// 消息接收端。
    public let sink = McpMessageSink()
    /// 诊断总线。
    public let diagnostics = McpDiagnostics()

    private var ownSession = false
    private var clientClosed = false

    public init(url: URL, headers: [String: String] = [:], session: URLSession? = nil) {
        self.url = url
        self.headers = headers
        if let session {
            self.session = session
        } else {
            self.session = URLSession(configuration: .ephemeral)
            ownSession = true
        }
    }

    /// 连接是否已建立且尚未断开。
    public var connected: Bool { sink.connected }

    /// 标记连接已建立。
    public func markConnected() { sink.connected = true }

    /// 标记连接已断开。
    public func markDisconnected() { sink.connected = false }

    public func messages() -> AsyncStream<McpTransportEvent> {
        sink.stream()
    }

    @discardableResult
    public func observeDiagnostics(_ body: @escaping @Sendable (String) -> Void) -> Int {
        diagnostics.observe(body)
    }

    public func send(_ message: McpMessage) async throws {
        try await postJSON(url, message)
    }

    public func disconnect() async {
        markDisconnected()
        closeClient()
        closeSinks()
    }

    // MARK: - 子类可覆写

    open func connect() async throws {
        markConnected()
    }

    // MARK: - 共用设施

    /// POST 一条 JSON-RPC 消息到 `target`。
    ///
    /// 非 200 抛 `McpException`（`http-status`）而非往消息流灌错误：一次 HTTP
    /// 失败不该判定整个会话断连，由调用方按次收敛。
    public func postJSON(_ target: URL, _ message: McpMessage) async throws {
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        var allHeaders = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ]
        for (key, value) in headers { allHeaders[key] = value }
        request.allHTTPHeaderFields = allHeaders
        let payload = try JSONValue.object(message.json).jsonData()
        request.httpBody = payload

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw McpException(McpException.Codes.httpStatus, "MCP POST 无 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            let body = String(decoding: data, as: UTF8.self)
            throw McpException(
                McpException.Codes.httpStatus,
                "MCP POST \(http.statusCode)：\(body)"
            )
        }
        deliverPayload(data, contentType: http.value(forHTTPHeaderField: "Content-Type"), sse: isEventStream(http))
    }

    /// 对 `target` 发起 `Accept: text/event-stream` 的 GET 长连接。
    ///
    /// 非 200 抛 `McpException`（`http-status`）；返回的响应供调用方消费。
    public func openStream(_ target: URL) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        var allHeaders = ["Accept": "text/event-stream"]
        for (key, value) in headers { allHeaders[key] = value }
        request.allHTTPHeaderFields = allHeaders

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw McpException(McpException.Codes.httpStatus, "MCP SSE 无 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw McpException(McpException.Codes.httpStatus, "MCP SSE \(http.statusCode)")
        }
        return (bytes, response)
    }

    /// 解析整包正文：`sse` 为真按 SSE 事件逐个解析，否则当单条 JSON。
    public func deliverPayload(_ data: Data, contentType: String?, sse: Bool) {
        let payload = String(decoding: data, as: UTF8.self)
        if sse {
            for event in parseMcpSsePayload(payload) {
                deliverJSON(event.data)
            }
            return
        }
        deliverJSON(payload)
    }

    /// 解析一条 JSON 载荷；解析不了只写诊断，不打断连接。
    public func deliverJSON(_ payload: String) {
        guard let decoded = McpDecode.text(payload),
              case let .object(json) = decoded else {
            diagnose("无法解析的 MCP 载荷：\(payload)")
            return
        }
        sink.emit(McpMessage(json: json))
    }

    /// 记一条诊断。
    public func diagnose(_ text: String) {
        diagnostics.log(text)
    }

    /// 关闭消息与诊断控制器；幂等。
    ///
    /// **不等消息流的结束**：`AsyncStream` 在没人消费时永远收不到结束，等它会让
    /// `disconnect` 永久挂起（来源的同款陷阱，见规格 S11 §5）。
    public func closeSinks() {
        sink.finish()
        diagnostics.dispose()
    }

    /// 关闭自建的 `URLSession`；调用方传入的 session 由调用方负责。
    public func closeClient() {
        guard ownSession, !clientClosed else { return }
        clientClosed = true
        session.invalidateAndCancel()
    }

    private func isEventStream(_ response: HTTPURLResponse) -> Bool {
        (response.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream")
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await session.data(for: request)
        return (data, response)
    }
}

/// 一发一收的 HTTP 传输（Streamable HTTP，规格 S11 §5）。
///
/// `send` 把消息 POST 到端点，响应正文既可以是单条 JSON-RPC 响应，也可以是
/// `text/event-stream` 正文（服务端选择流式形态时，正文里可能有多条消息）。
/// 服务端主动推送（没有对应请求的消息）不在此列——需要它就用 `SseTransport`。
///
/// `connect` 不发请求：HTTP 没有需要预先建立的连接，只标记就绪。
public final class HttpTransport: McpHttpTransport {
    /// 端点地址非法时抛 `McpException`（配置里的 url 通常已过 `URL(string:)`，
    /// 这里只兜住运行期拼出来的地址）。
    public convenience init(urlString: String, headers: [String: String] = [:], session: URLSession? = nil) throws {
        guard let url = URL(string: urlString) else {
            throw McpException(McpException.Codes.httpStatus, "MCP 端点地址不合法：\(urlString)")
        }
        self.init(url: url, headers: headers, session: session)
    }

    override public func connect() async throws {
        markConnected()
    }
}

/// `text/event-stream` 长连接 + 一次性 POST 端点的传输（规格 S11 §5）。
///
/// `connect` 对端点发 `GET`，服务端会先发一个 `event: endpoint` 事件，其
/// `data` 是（可能相对的）POST 地址；此后的请求 POST 到该地址，**响应（含服务端
/// 主动推送）都从长连接上来**。
public final class SseTransport: McpHttpTransport {
    private var streamTask: Task<Void, Never>?
    private var endpointURL: URL?

    /// 端点地址非法时抛 `McpException`。
    public convenience init(urlString: String, headers: [String: String] = [:], session: URLSession? = nil) throws {
        guard let url = URL(string: urlString) else {
            throw McpException(McpException.Codes.httpStatus, "MCP 端点地址不合法：\(urlString)")
        }
        self.init(url: url, headers: headers, session: session)
    }

    /// 服务端在 `event: endpoint` 里给出的 POST 地址；握手前为 nil。
    public var endpoint: URL? { endpointURL }

    public override func connect() async throws {
        let (bytes, _) = try await openStream(url)
        markConnected()
        streamTask = Task { [weak self] in
            await self?.pump(bytes)
        }
    }

    public override func send(_ message: McpMessage) async throws {
        try await postJSON(endpointURL ?? url, message)
    }

    override public func disconnect() async {
        streamTask?.cancel()
        streamTask = nil
        markDisconnected()
        closeClient()
        closeSinks()
    }

    /// 消费长连接：逐块喂给 SSE 解析器。
    private func pump(_ bytes: URLSession.AsyncBytes) async {
        var parser = McpSseParser()
        var state = McpSseParser.State()
        do {
            for try await byte in bytes {
                if Task.isCancelled { return }
                for event in parser.consume([byte], state: &state) {
                    handle(event)
                }
            }
            for event in parser.finish(&state) {
                handle(event)
            }
            sink.emitFailure(McpException(McpException.Codes.sseClosed, "SSE 长连接已结束"))
            sink.finish()
        } catch {
            if Task.isCancelled { return }
            sink.emitFailure(McpException(McpException.Codes.sseError, "\(error)"))
            sink.finish()
        }
    }

    private func handle(_ event: SseEvent) {
        if event.event == "endpoint" {
            endpointURL = resolveEndpoint(event.data)
            return
        }
        deliverJSON(event.data)
    }

    /// `event: endpoint` 的 `data` 可能是相对地址；按长连接端点解析。
    private func resolveEndpoint(_ data: String) -> URL? {
        guard let parsed = URL(string: data) else { return nil }
        if parsed.scheme != nil { return parsed }
        return URL(string: data, relativeTo: url)?.absoluteURL
    }
}
