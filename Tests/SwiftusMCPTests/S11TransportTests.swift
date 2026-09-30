import Foundation
import SwiftusCore
import SwiftusCredentials
import SwiftusFoundation
import SwiftusMCP
import Testing

/// S11 传输层单元测试（fixtures **不覆盖**传输层——它们要么要真子进程、要么要
/// HTTP 桩，都是语言相关的注入点；见 exporter README 的 S11 段）。
///
/// 串行纪律：本套件用到进程级 URLProtocol 桩注册表，而 swift-testing 并发跑用例，
/// 故整体标 `.serialized`。用 `NSLock` 串行会在协作线程池上死锁（持锁线程占满
/// → URLSession 回调拿不到线程 → 全部挂起），本项目已踩过。
@Suite("S11 传输层", .serialized)
struct S11TransportTests {

    // MARK: HTTP 传输

    @Test("HTTP 传输：POST 带双 Accept 与配置头；JSON 与 SSE 两种响应都进消息流")
    @ContextTreeActor
    func httpTransport() async throws {
        let registry = McpStubRegistry()
        let session = registry.makeSession()
        let transport = HttpTransport(
            url: try #require(URL(string: "https://mcp.test/mcp")),
            headers: ["Authorization": "Bearer t"],
            session: session
        )
        // connect 不发请求，只标记就绪。
        try await transport.connect()
        #expect(transport.connected)
        // 诊断必须在发送**之前**挂上：坏载荷是在 send 里同步记的。
        let diagnostics = McpDiagnosticBox()
        transport.observeDiagnostics { text in diagnostics.append(text) }
        let events = mcpCollect(transport)

        // 1) 普通 JSON 响应：单条消息。
        registry.enqueue(path: "/mcp", McpStubRegistry.Stub(
            body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.utf8),
            contentType: "application/json; charset=utf-8"
        ))
        try await transport.send(.request(id: 1, method: "tools/list"))
        // 2) text/event-stream 响应：逐事件解析，坏载荷只写诊断。
        registry.enqueue(path: "/mcp", McpStubRegistry.Stub(
            body: Data("""
            data: {"jsonrpc":"2.0","id":2,"result":{}}

            data: 不是 JSON

            data: {"jsonrpc":"2.0","id":3,"result":{}}

            """.utf8),
            contentType: "text/event-stream; charset=utf-8"
        ))
        try await transport.send(.request(id: 2, method: "tools/call"))

        await mcpSettle()
        let received = events
        #expect(received.messages.map { $0.id } == [JSONValue.int(1), .int(2), .int(3)])
        #expect(received.failures.isEmpty, "坏载荷不该当断连")
        #expect(diagnostics.items.count == 1, "坏载荷只写诊断：\(diagnostics.items)")
        #expect(diagnostics.items.first?.contains("无法解析的 MCP 载荷") == true)

        // 请求形状：方法 / 头 / 体。
        let recorded = registry.recordedRequests
        #expect(recorded.count == 2)
        #expect(recorded.allSatisfy { $0.method == "POST" })
        let accept = recorded.first?.headerNames["accept"] ?? ""
        #expect(accept.contains("application/json"))
        #expect(accept.contains("text/event-stream"))
        #expect(recorded.first?.headerNames["content-type"] == "application/json")
        #expect(recorded.first?.headerNames["authorization"] == "Bearer t")
        // 请求体逐字锁 `jsonrpc: "2.0"`（协议的一部分）。
        #expect(recorded.first?.body?["jsonrpc"]?.stringValue == "2.0")
        #expect(recorded.first?.body?["method"]?.stringValue == "tools/list")

        await transport.disconnect()
        #expect(transport.connected == false, "disconnect 后 connected 复位")
    }

    @Test("HTTP 传输：非 200 抛 http-status，且不当作断连")
    @ContextTreeActor
    func httpStatusFailure() async throws {
        let registry = McpStubRegistry()
        let session = registry.makeSession()
        let transport = HttpTransport(
            url: try #require(URL(string: "https://mcp.test/mcp")),
            session: session
        )
        try await transport.connect()
        let events = mcpCollect(transport)
        registry.enqueue(path: "/mcp", McpStubRegistry.Stub(status: 503, body: Data("后端不可用".utf8)))
        await #expect(throws: McpException.self) {
            try await transport.send(.request(id: 1, method: "tools/list"))
        }
        await mcpSettle()
        let received = events
        #expect(received.messages.isEmpty, "一次 HTTP 失败不该产生消息")
        #expect(received.failures.isEmpty, "一次 HTTP 失败不该判定断连")
        #expect(transport.connected, "connected 不该被单次失败复位")
        await transport.disconnect()
    }

    @Test("HTTP 传输：错误文案带状态码与正文")
    @ContextTreeActor
    func httpStatusMessage() async throws {
        let registry = McpStubRegistry()
        let transport = HttpTransport(
            url: try #require(URL(string: "https://mcp.test/mcp")),
            session: registry.makeSession()
        )
        try await transport.connect()
        registry.enqueue(path: "/mcp", McpStubRegistry.Stub(status: 500, body: Data("炸了".utf8)))
        do {
            try await transport.send(.request(id: 1, method: "x"))
            Issue.record("应当抛 http-status")
        } catch let error as McpException {
            #expect(error.code == McpException.Codes.httpStatus)
            #expect(error.message == "MCP POST 500：炸了")
        }
        await transport.disconnect()
    }

    // MARK: SSE 传输

    @Test("SSE 传输：先收 endpoint 事件，之后 POST 到该地址、响应从长连接来")
    @ContextTreeActor
    func sseTransport() async throws {
        let registry = McpStubRegistry()
        let transport = SseTransport(
            url: try #require(URL(string: "https://mcp.test/sse")),
            session: registry.makeSession()
        )
        // GET 建长连接：先给 endpoint（相对地址），随后推响应。
        registry.enqueueStream(path: "/sse", McpStubRegistry.StreamStub(
            opens: [
                "event: endpoint\ndata: /messages?session=1\n\n",
            ]
        ))
        let events = mcpCollect(transport)
        try await transport.connect()

        // endpoint 是相对地址 → 按长连接端点解析。
        let endpoint = await mcpAwaitEndpoint(transport)
        #expect(endpoint?.absoluteString == "https://mcp.test/messages?session=1")

        // POST 走 endpoint 地址；**响应只能从长连接上来**（POST 应答是空的）。
        registry.enqueue(path: "/messages", McpStubRegistry.Stub(
            body: Data(),
            contentType: "text/event-stream; charset=utf-8"
        ))
        registry.push(path: "/sse", "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n\n")
        try await transport.send(.request(id: 1, method: "tools/list"))

        await mcpSettle()
        let received = events
        #expect(received.messages.count == 1)
        #expect(received.messages.first?.method == nil, "长连接上的是响应")
        let posts = registry.recordedRequests.filter { $0.method == "POST" }
        #expect(posts.count == 1, "POST 应落到 endpoint 地址")
        #expect(posts.first?.path == "/messages")
        #expect(posts.first?.query["session"] == "1")
        await transport.disconnect()
    }

    @Test("SSE 传输：GET 非 200 抛 MCP SSE <code>")
    @ContextTreeActor
    func sseOpenFailure() async throws {
        let registry = McpStubRegistry()
        let transport = SseTransport(
            url: try #require(URL(string: "https://mcp.test/sse")),
            session: registry.makeSession()
        )
        registry.enqueueStream(path: "/sse", McpStubRegistry.StreamStub(opens: [], status: 401))
        do {
            try await transport.connect()
            Issue.record("应当抛 http-status")
        } catch let error as McpException {
            #expect(error.code == McpException.Codes.httpStatus)
            #expect(error.message == "MCP SSE 401")
        }
        await transport.disconnect()
    }

    @Test("SSE 传输：长连接结束 → sse-closed 并关闭消息流")
    @ContextTreeActor
    func sseClosed() async throws {
        let registry = McpStubRegistry()
        let transport = SseTransport(
            url: try #require(URL(string: "https://mcp.test/sse")),
            session: registry.makeSession()
        )
        registry.enqueueStream(path: "/sse", McpStubRegistry.StreamStub(opens: []))
        let events = mcpCollect(transport)
        try await transport.connect()
        _ = await mcpAwaitEndpoint(transport)
        registry.closeStream(path: "/sse")
        await mcpAwait { events.finished }
        let received = events
        let failure = received.failures.first as? McpException
        #expect(failure?.code == McpException.Codes.sseClosed)
        #expect(received.finished, "长连接结束后消息流应关闭")
        await transport.disconnect()
    }

    // MARK: 端到端

    @Test("端到端：HTTP 传输 + 客户端握手 / 发现 / 调用 / 关闭")
    @ContextTreeActor
    func httpEndToEnd() async throws {
        let registry = McpStubRegistry()
        let session = registry.makeSession()
        let client = McpClient(
            transport: HttpTransport(
                url: try #require(URL(string: "https://mcp.test/mcp")),
                session: session
            ),
            serverName: "remote"
        )

        // 握手响应。
        registry.enqueue(path: "/mcp", McpStubRegistry.Stub(
            body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"remote","version":"1.0"}}}"#.utf8)
        ))
        // `notifications/initialized` 也是一次 POST（通知单向上行，仍走端点）。
        registry.enqueue(path: "/mcp", McpStubRegistry.Stub(
            body: Data(),
            contentType: "text/event-stream; charset=utf-8"
        ))
        let info = try await client.initialize()
        #expect(info.name == "remote")
        #expect(client.ready)

        registry.enqueue(path: "/mcp", McpStubRegistry.Stub(
            body: Data(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"read_file","description":"读文件","annotations":{"readOnlyHint":true}}]}}"#.utf8)
        ))
        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(tools.first?.name == "read_file")

        registry.enqueue(path: "/mcp", McpStubRegistry.Stub(
            body: Data(#"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"文件内容"}]}}"#.utf8)
        ))
        let called = try await client.callTool("read_file", ["path": .string("/tmp/a")])
        #expect(describeMcpContent(called.content) == "文件内容")

        await client.close()
        #expect(client.ready == false)
    }

    #if os(macOS)
    @Test("stdio 端到端：真子进程跑通握手 / 发现 / 调用")
    @ContextTreeActor
    func stdioEndToEnd() async throws {
        let server = try await mcpBuildEchoServer()
        let client = McpClient(
            transport: StdioTransport(command: server.path),
            serverName: "echo",
            // 子进程启动要时间（冷启动尤其慢），超时给足。
            timeout: .seconds(30)
        )
        let info = try await client.initialize()
        #expect(info.name == "echo")
        #expect(info.version == "0.0.1")
        #expect(info.protocolVersion == kMcpProtocolVersion)
        #expect(client.ready)

        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(tools.first?.name == "echo")
        #expect(tools.first?.inputSchema["required"] == .array([.string("text")]))

        let result = try await client.callTool("echo", ["text": .string("你好"), "n": .int(2)])
        #expect(result.failed == false)
        #expect(describeMcpContent(result.content) == #"{"n":2,"text":"你好"}"#)
        #expect(result.structuredContent?["text"]?.stringValue == "你好")

        await client.close()
        #expect(client.ready == false)
    }

    @Test("MCP 工具的入参 schema 经 any Tool 存在值透传给模型（覆写不被静默忽略）")
    @ContextTreeActor
    func schemaOverrideSurvivesExistential() async throws {
        // 回归用例：`schema` 曾只定义在 `Tool` 的扩展里，于是 `any Tool` 上的成员
        // 访问被静态派发到扩展那份实现（按 `params` 生成），MCP 适配器的覆写
        // （透传服务端 `inputSchema`）被静默忽略——fixtures 直接调具体类型所以
        // 测不出来，是 Demo 端到端先发现的。
        let context = Context.root()
        let tools = try provideTools(context)
        let client = McpClient(transport: ScriptedMcpTransport(), serverName: "fs")
        let tool = McpTool(json: [
            "name": .string("read_file"),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(["path": .object(["type": .string("string")])]),
                "required": .array([.string("path")]),
            ]),
        ])
        try tools.register(McpToolAdapter(client: client, tool: tool))

        // 经注册表投影（`any Tool`）读到的必须是服务端下发的 schema。
        let described = try #require(tools.describeOne("fs__read_file"))
        #expect(described["parameters"]?["required"] == .array([.string("path")]))
        #expect(described["parameters"]?["properties"]?["path"]?["type"] == .string("string"))
        context.dispose()
    }

    @Test("stdio 传输：未连接就发送抛 not-connected")
    @ContextTreeActor
    func stdioNotConnected() async throws {
        let transport = StdioTransport(command: "/nonexistent/mcp-server")
        do {
            try await transport.send(.request(id: 1, method: "tools/list"))
            Issue.record("应当抛 not-connected")
        } catch let error as McpException {
            #expect(error.code == McpException.Codes.notConnected)
        }
    }

    @Test("stdio 传输：子进程退出 → server-exited 并关闭消息流")
    @ContextTreeActor
    func stdioServerExited() async throws {
        // `/bin/echo` 立刻退出：正好模拟「服务端崩了」。
        let transport = StdioTransport(command: "/bin/echo", args: ["已退出"])
        let events = mcpCollect(transport)
        try await transport.connect()
        // 等「故障已投递且流已关闭」，而不是等固定时长。
        await mcpAwait { events.finished }
        let failure = events.failures.first as? McpException
        #expect(failure?.code == McpException.Codes.serverExited)
        #expect(events.finished, "子进程退出后消息流应关闭")
        await transport.disconnect()
        #expect(transport.connected == false)
    }

    @Test("stdio 传输：命令起不来时 connect 抛 not-connected")
    @ContextTreeActor
    func stdioConnectFailure() async throws {
        let transport = StdioTransport(command: "/nonexistent/mcp-server")
        do {
            try await transport.connect()
            Issue.record("应当抛 not-connected")
        } catch let error as McpException {
            #expect(error.code == McpException.Codes.notConnected)
        }
    }
    #endif

    // MARK: 一次性实例

    @Test("传输实例一次性：disconnect 后 connected 复位，不支持重连")
    @ContextTreeActor
    func oneShotInstance() async throws {
        let transport = HttpTransport(
            url: try #require(URL(string: "https://mcp.test/mcp")),
            session: McpStubRegistry().makeSession()
        )
        try await transport.connect()
        #expect(transport.connected)
        await transport.disconnect()
        #expect(transport.connected == false)
        // 二次 disconnect 幂等。
        await transport.disconnect()
    }

    @Test("消息流单订阅：第二次取流得到空流；订阅前的数据被缓冲")
    @ContextTreeActor
    func singleSubscription() async throws {
        let sink = McpMessageSink()
        // 订阅**之前**投递：必须被缓冲并在订阅时回放。
        sink.emit(McpMessage(json: ["id": .int(1), "result": .object([:])]))
        var seen: [McpMessage] = []
        for await event in sink.stream() {
            if case let .message(message) = event { seen.append(message) }
            if seen.count == 1 { break } // 别等流结束：缓冲只有一条
        }
        #expect(seen.count == 1)
        // 单订阅：第二次拿到的是空流。
        var second = 0
        for await _ in sink.stream() { second += 1 }
        #expect(second == 0)
    }

    @Test("iOS 专属面：stdio 配置在非 macOS 上装配失败并说明原因")
    @ContextTreeActor
    func unsupportedTransport() async throws {
        #if os(macOS)
        // macOS 上 stdio 可用：默认传输是 StdioTransport。
        let config = try McpServerConfig(name: "fs", type: .stdio, command: "npx")
        #expect(defaultMcpTransport(config) is StdioTransport)
        #else
        let config = try McpServerConfig(name: "fs", type: .stdio, command: "npx")
        let transport = defaultMcpTransport(config)
        #expect(transport is UnsupportedMcpTransport)
        await #expect(throws: McpException.self) { try await transport.connect() }
        #endif
        // 空 url 在**配置构造期**就被拒（规格 S11 §2），根本走不到传输分派。
        #expect(throws: McpConfigError.self) {
            try McpServerConfig(name: "r", type: .http, url: "")
        }
        // 非空但非法的地址走占位传输：给一条明确的失败通道而不是 nil 传输。
        let bad = try McpServerConfig(name: "r", type: .http, url: "ht tp://坏地址")
        #expect(defaultMcpTransport(bad) is UnsupportedMcpTransport)
    }

    @Test("装配：别名与凭据占位符在装配期解析（env / headers）")
    @ContextTreeActor
    func assemblyResolvesPlaceholders() async throws {
        let context = Context.root()
        _ = try provideTools(context)
        let credentials = InMemoryCredentials()
        try await credentials.update("MCP_TOKEN", "secret-1")

        let config = try McpServerConfig(
            name: "remote",
            type: .http,
            url: "https://mcp.test/mcp",
            // Swift 字符串里 `\${` 不合法，用拼接写出占位符。
            headers: ["Authorization": "Bearer " + "$" + "{MCP_TOKEN}"]
        )
        let seen = McpConfigBox()
        let registry = try await provideMcp(
            context,
            [config],
            credentials: credentials,
            transportFactory: { resolved in
                seen.config = resolved
                return ScriptedMcpTransport()
            }
        )
        // 占位符在**装配期**就替换掉了，且返回值不得进日志（规格 S11 §8）。
        #expect(seen.config?.headers["Authorization"] == "Bearer secret-1")
        #expect(registry.servers == ["remote"])
        // 假传输没有工具，别名目标不存在 → 明确失败。
        #expect(throws: McpRegistryError.self) {
            try registry.addAlias(context, "read_file", "remote__read_file")
        }
        await registry.close()
        #expect(registry.servers.isEmpty)
        context.dispose()
    }
}

// MARK: - 收集助手

/// 后台消费消息流，把事件攒进一个盒子供断言。
///
/// **不等「攒够 N 条」**：本域有多条用例断言的正是「一条都不该来」（单次 HTTP
/// 失败不当断连、坏载荷只写诊断），等够 N 条会永久挂住。改为起一个消费 Task、
/// 由断言侧有界沉降后读盒子。
@ContextTreeActor
func mcpCollect(_ transport: any McpTransport) -> McpCollected {
    let box = McpCollected()
    let stream = transport.messages()
    Task { @ContextTreeActor in
        for await event in stream {
            switch event {
            case let .message(message): box.append(.message(message))
            case let .failure(error): box.append(.failure(error))
            case .finished: box.append(.finished)
            }
        }
        box.markStreamEnd()
    }
    return box
}

/// 事件盒（跨 Task 读，故加锁）。
final class McpCollected: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [McpTransportEvent] = []
    private var streamEnded = false

    func append(_ event: McpTransportEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func markStreamEnd() {
        lock.lock(); defer { lock.unlock() }
        streamEnded = true
    }

    var all: [McpTransportEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    var messages: [McpMessage] {
        all.compactMap { if case let .message(message) = $0 { message } else { nil } }
    }

    var failures: [any Error] {
        all.compactMap { if case let .failure(error) = $0 { error } else { nil } }
    }

    var finished: Bool {
        all.contains { if case .finished = $0 { true } else { false } } || streamEnded
    }
}

/// 有界沉降：等微任务与 HTTP 回调落定（**不固定 sleep**，见坑 #8）。
@ContextTreeActor
func mcpSettle(rounds: Int = 40) async {
    for _ in 0..<rounds {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// **有界轮询直到条件成立**，不等固定轮数。
///
/// `mcpSettle(rounds:)` 是「等这么久再看」，条件没成立就只当没发生——本仓在
/// `stdio 传输：子进程退出` 上踩过：全量并发时 `/bin/echo` 退出 + 收口比 60 轮
/// 慢，用例偶发红。凡是「等某件事发生」都要走这个形状（坑 #8 同一纪律）。
@ContextTreeActor
func mcpAwait(
    rounds: Int = 300,
    _ condition: @escaping @ContextTreeActor () -> Bool
) async {
    for _ in 0..<rounds {
        if condition() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// 有界轮询等 endpoint 就位（长连接是异步喂的）。
@ContextTreeActor
func mcpAwaitEndpoint(_ transport: SseTransport, rounds: Int = 100) async -> URL? {
    for _ in 0..<rounds {
        if let endpoint = transport.endpoint { return endpoint }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
}

#if os(macOS)
/// 编译回声 MCP server（stdio 端到端测试用），返回可执行文件路径。
///
/// **先编译再跑**：`/usr/bin/env swift script.swift` 走解释执行，冷启动要好几秒，
/// 会把用例拖成「挂住」。`swiftc` 编一次不到 1 秒，缓存在构建目录里复用。
/// 编译不可用时显式跳过（不静默通过）。
@ContextTreeActor
func mcpBuildEchoServer() async throws -> URL {
    let cache = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "swiftus-echo-mcp-server")
    if FileManager.default.isExecutableFile(atPath: cache.path()) {
        return cache
    }
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "EchoMcpServer.swift")
    guard FileManager.default.fileExists(atPath: script.path()) else {
        throw McpException("missing-script", "找不到回声 server 脚本：\(script.path())")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swiftc", "-O", script.path(), "-o", cache.path()]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        throw McpException("no-compiler", "本机没有 swiftc，跳过 stdio 端到端：\(error)")
    }
    // `waitUntilExit` 阻塞：放专用线程，别占着协作线程池（见 StdioTransport 的同款说明）。
    let status: Int32 = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            continuation.resume(returning: process.terminationStatus)
        }
    }
    guard status == 0,
          FileManager.default.isExecutableFile(atPath: cache.path()) else {
        throw McpException("compile-failed", "回声 server 编译失败（退出码 \(status)）。")
    }
    return cache
}
#endif

/// 收集诊断文本（诊断是同步投递的，但经 `@Sendable` 闭包故要加锁）。
final class McpDiagnosticBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(text)
    }

    var items: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// 装配置期看到的 `McpServerConfig`（断言占位符已解析）。
@ContextTreeActor
final class McpConfigBox {
    var config: McpServerConfig?
}
