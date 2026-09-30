import Foundation
import SwiftusCore

/// S11 传输层测试的 URLProtocol 桩（规格 S11 §5 的 URLSession 注入点）。
///
/// 按 **host + path** 分桶：S11 的桩端点都挂在同一台探测主机上（`mcp.test`），
/// path 必须进键才不至于共用队列。
///
/// 串行纪律：注册表是进程级单例，而 swift-testing 并发跑用例——用到桩的套件整体
/// 标 `.serialized`。**不要用 `NSLock` 串行**：会在协作线程池上死锁（持锁线程占满
/// → URLSession 回调拿不到线程 → 全部挂起），本项目已在 S20 踩过。
final class McpStubProtocol: URLProtocol {
    /// 当前生效的注册表。
    ///
    /// `URLProtocol` 实例由 URLSession 内部创建，拿不到测试持有的注册表引用，
    /// 故由 `makeSession()` 把自己装成 active（套件整体 `.serialized`，无并发）。
    static let activeBox = McpActiveRegistryBox()

    /// 当前长连接的闸门（`URLProtocol` 实例持有，`stopLoading` 时释放）。
    private var channel: McpStreamChannel?
    /// 回调侧的状态盒。
    ///
    /// `URLProtocol` 本身不是 `Sendable`，不能直接进 `@Sendable` 闭包；于是把
    /// 「client + 是否已停」放进一个 `@unchecked Sendable` 盒，`stopLoading` 置位
    /// 后所有回调短路（`URLProtocol` 的契约也要求停后不再回调 client）。
    private final class CallbackBox: @unchecked Sendable {
        private unowned let owner: McpStubProtocol
        private weak var client: URLProtocolClient?
        private let lock = NSLock()
        private var stopped = false

        init(owner: McpStubProtocol, client: URLProtocolClient?) {
            self.owner = owner
            self.client = client
        }

        func load(_ text: String) {
            lock.lock()
            let isStopped = stopped
            let client = self.client
            lock.unlock()
            guard !isStopped, let client else { return }
            client.urlProtocol(owner, didLoad: Data(text.utf8))
        }

        func finish() {
            lock.lock()
            let isStopped = stopped
            let client = self.client
            lock.unlock()
            guard !isStopped, let client else { return }
            client.urlProtocolDidFinishLoading(owner)
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            stopped = true
            client = nil
        }
    }

    private var box: CallbackBox?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.activeBox.registry?.record(request)

        // GET = 建长连接（SSE）。
        if request.httpMethod == "GET" {
            guard let stream = Self.activeBox.registry?.takeStream(for: url) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            guard stream.status == 200 else {
                let response = HTTPURLResponse(
                    url: url, statusCode: stream.status, httpVersion: "HTTP/1.1", headerFields: [:]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream; charset=utf-8"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // 订阅闸门：后续 `push` / `closeStream` 经它驱动长连接。
            let channel = stream.channel
            self.channel = channel
            let box = CallbackBox(owner: self, client: client)
            self.box = box
            channel.subscribe { text in box.load(text) } onClose: { box.finish() }
            return
        }

        // POST = 一发一收。
        guard let stub = Self.activeBox.registry?.takeStub(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": stub.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        box?.stop()
        box = nil
        channel?.unsubscribe()
        channel = nil
    }
}

/// active 注册表的持有者（`URLProtocol` 静态方法只能碰这个）。
final class McpActiveRegistryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: McpStubRegistry?

    var registry: McpStubRegistry? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ registry: McpStubRegistry) {
        lock.lock(); defer { lock.unlock() }
        storage = registry
    }
}

/// S11 桩注册表：按 host + path 分桶，记录请求并回放响应 / 驱动长连接。
final class McpStubRegistry: @unchecked Sendable {
    struct Stub {
        var status: Int = 200
        var body: Data = Data()
        var contentType = "application/json; charset=utf-8"
        var failure: URLError?
    }

    /// 长连接桩：`opens` 是建连后立即推的字节，之后靠 `push` / `closeStream` 驱动。
    final class StreamStub {
        let status: Int
        let channel: McpStreamChannel

        init(opens: [String], status: Int = 200) {
            self.status = status
            channel = McpStreamChannel()
            // 建连首段：URLProtocol 订阅**之前**就投递，靠闸门缓冲兜住
            // （SSE 的 `event: endpoint` 正是这样先到的）。
            for chunk in opens { channel.push(chunk) }
        }
    }

    struct Recorded {
        let method: String
        let host: String
        let path: String
        let query: [String: String]
        let headerNames: [String: String]
        let body: JSONValue?
    }

    private let lock = NSLock()
    private var stubs: [String: [Stub]] = [:]
    private var streams: [String: [StreamStub]] = [:]
    private var channels: [String: McpStreamChannel] = [:]
    private var recorded: [Recorded] = []

    /// 造一个走桩的 `URLSession`，并把自己装成 active 注册表。
    func makeSession() -> URLSession {
        McpStubProtocol.activeBox.set(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [McpStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    func enqueue(path: String, _ stub: Stub) {
        lock.lock(); defer { lock.unlock() }
        stubs[key(path), default: []].append(stub)
    }

    func enqueueStream(path: String, _ stub: StreamStub) {
        lock.lock(); defer { lock.unlock() }
        streams[key(path), default: []].append(stub)
    }

    /// 往长连接推一段字节。
    func push(path: String, _ text: String) {
        lock.lock()
        let channel = channels[key(path)]
        lock.unlock()
        channel?.push(text)
    }

    /// 关闭长连接。
    func closeStream(path: String) {
        lock.lock()
        let channel = channels[key(path)]
        lock.unlock()
        channel?.close()
    }

    /// 已记录的请求（按序）。
    var recordedRequests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(_ request: URLRequest) {
        guard let url = request.url else { return }
        var body = request.httpBody
        if body == nil, let httpBodyStream = request.httpBodyStream {
            httpBodyStream.open()
            defer { httpBodyStream.close() }
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            // 读循环**必须有上界**：读尽后 `read` 可能阻塞而不返回 0
            // （本项目在 S20 挂过一次）。
            for _ in 0..<8 {
                let read = httpBodyStream.read(&chunk, maxLength: chunk.count)
                if read <= 0 { break }
                buffer.append(chunk, count: read)
            }
            body = buffer
        }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        lock.lock(); defer { lock.unlock() }
        recorded.append(Recorded(
            method: request.httpMethod ?? "GET",
            host: url.host ?? "",
            path: url.path,
            query: query,
            headerNames: headers,
            body: body.flatMap { try? JSONValue.parse($0) }
        ))
    }

    /// 取出待回放的响应（按登记序消费）。
    func takeStub(for url: URL) -> Stub? {
        lock.lock(); defer { lock.unlock() }
        guard var queue = stubs[key(url.path)], !queue.isEmpty else { return nil }
        let head = queue.removeFirst()
        stubs[key(url.path)] = queue
        return head
    }

    /// 取出长连接桩并登记闸门（供 `push` / `closeStream` 驱动）。
    func takeStream(for url: URL) -> StreamStub? {
        lock.lock(); defer { lock.unlock() }
        guard var queue = streams[key(url.path)], !queue.isEmpty else { return nil }
        let head = queue.removeFirst()
        streams[key(url.path)] = queue
        channels[key(url.path)] = head.channel
        return head
    }

    private func key(_ path: String) -> String {
        "mcp.test\(path)"
    }
}

/// 长连接的回调闸门：桩侧 `push` / `close`，URLProtocol 侧订阅。
///
/// **单订阅 + 订阅前缓冲**：SSE 的首段（`event: endpoint`）在 URLProtocol 订阅
/// 之前就投递，没有缓冲就会丢。
final class McpStreamChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var onText: (@Sendable (String) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var buffered: [String] = []
    private var closed = false

    func subscribe(
        onText: @escaping @Sendable (String) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        guard self.onText == nil else {
            lock.unlock()
            return
        }
        self.onText = onText
        self.onClose = onClose
        let replay = buffered
        buffered = []
        let isClosed = closed
        lock.unlock()
        for text in replay { onText(text) }
        if isClosed { onClose() }
    }

    func unsubscribe() {
        lock.lock(); defer { lock.unlock() }
        onText = nil
        onClose = nil
    }

    func push(_ text: String) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        guard let onText else {
            buffered.append(text)
            lock.unlock()
            return
        }
        lock.unlock()
        onText(text)
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let onClose = onClose
        self.onClose = nil
        self.onText = nil
        lock.unlock()
        onClose?()
    }
}
