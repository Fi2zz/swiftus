import Foundation
import SwiftusCore
import SwiftusCredentials
import SwiftusFoundation
import SwiftusSearch
import Testing

/// S20 fixture（{name, kind, cases}）；每个用例自带 `input`。
struct S20Fixture {
    let name: String
    let kind: String
    let raw: JSONValue
    let cases: [JSONValue]
}

enum S20FixtureLoader {
    /// 全部 kind。
    static let kinds = [
        "search-service", "search-registry", "search-markup",
        "search-providers", "search-fetch", "search-web-tools",
    ]

    /// fixture 名（按 kind 过滤、排序）——参数化只拿名字，失败输出不拖整份 fixture。
    static func names(kind: String) -> [String] {
        load(kind: kind).map(\.name)
    }

    /// 全部 fixture。
    static func loadAll() -> [S20Fixture] {
        kinds.flatMap { load(kind: $0) }
    }

    /// 按名字取一份 fixture。
    static func load(named name: String) -> S20Fixture? {
        loadAll().first { $0.name == name }
    }

    /// 按 kind 装载（spec/fixtures/s20）。
    static func load(kind: String) -> [S20Fixture] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "spec/fixtures/s20", directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path()) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .compactMap { name in
                guard let root = try? JSONValue.parse(Data(contentsOf: directory.appending(path: name))).objectValue,
                      root["kind"]?.stringValue == kind else {
                    return nil
                }
                return S20Fixture(
                    name: root["name"]?.stringValue ?? name,
                    kind: kind,
                    raw: .object(root),
                    cases: root["cases"]?.arrayValue ?? []
                )
            }
    }
}

// MARK: - 替身

/// 脚本化 provider：按输入决定返回还是抛错。
@ContextTreeActor
final class ScriptedProvider: SearchProvider {
    let name: String
    private let spec: [String: JSONValue]

    init(_ spec: [String: JSONValue]) {
        name = spec["name"]?.stringValue ?? "?"
        self.spec = spec
    }

    func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        if case .some(.bool(true)) = spec["fails"] {
            throw SearchException(spec["error"]?.stringValue ?? "boom")
        }
        return (spec["results"]?.arrayValue ?? []).compactMap { item in
            guard let row = item.objectValue else { return nil }
            return SearchResult(
                title: row["title"]?.stringValue ?? "",
                url: row["url"]?.stringValue ?? "",
                snippet: row["snippet"]?.stringValue ?? ""
            )
        }
    }
}

/// 按 fixture 的 `providers` 造一个服务（可选带 statuses）。
@ContextTreeActor
func s20Service(
    _ providers: [JSONValue],
    statuses: [JSONValue] = []
) -> SearchService {
    let parsed: [SearchSourceStatus] = statuses.compactMap { item -> SearchSourceStatus? in
        guard let row = item.objectValue, let name = row["name"]?.stringValue else { return nil }
        return SearchSourceStatus(
            name: name,
            available: { if case .some(.bool(true)) = row["available"] { return true }; return false }(),
            reason: row["reason"]?.stringValue ?? ""
        )
    }
    let service = SearchService(statuses: parsed)
    for spec in providers {
        guard let row = spec.objectValue else { continue }
        service.register(ScriptedProvider(row))
    }
    return service
}

/// 结果数组的投影。
func s20Results(_ results: [SearchResult]) -> JSONValue {
    .object(["results": .array(results.map { .object($0.json) })])
}

/// 异常 → `{error: 消息}` 或 `{errorPrefix: 前缀}`。
@ContextTreeActor
func s20Guard(
    _ body: () async throws -> JSONValue,
    prefix: String? = nil
) async -> JSONValue {
    do {
        return try await body()
    } catch let error as SearchException {
        return prefix == nil
            ? .object(["error": .string(error.message)])
            : .object(["errorPrefix": .string(prefix!)])
    } catch let error as FetchException {
        return prefix == nil
            ? .object(["error": .string(error.message)])
            : .object(["errorPrefix": .string(prefix!)])
    } catch {
        return .object(["unexpected": .string(String(describing: type(of: error)))])
    }
}

// MARK: - URLProtocol 桩

/// 记录请求并回放固定响应的桩（按 authority 分桶，spec/fixtures 里的端点各不相同）。
final class S20StubProtocol: URLProtocol {
    static let registry = S20StubRegistry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.registry.takeStub(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        // URLProtocol 会把 POST 的 body 挪进 httpBodyStream，故两路都读。
        // 读循环**必须有上界**：既不能只信 `hasBytesAvailable`（URLSession 喂的流
        // 在 open() 之后该标志可能一直是假），也不能 `while read > 0` 读到天荒地老
        // （读尽后 `read` 可能阻塞而不返回 0——本项目在这挂过一次）。请求体都很小，
        // 按「最多 8 块 / 32KB」收口。
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<8 {
                let read = stream.read(&chunk, maxLength: chunk.count)
                if read <= 0 { break }
                buffer.append(chunk, count: read)
            }
            body = buffer
        }
        Self.registry.record(request, body: body)
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

    override func stopLoading() {}
}

/// 按 **host:port + path** 分桶的桩注册表。
///
/// 只按 host:port 分桶不够：S20 的所有 fixture 端点都挂在同一探测主机上
/// （`probe.test` / `example.com`），path 也要进键才不至于共用队列。
///
/// 串行纪律：注册表是进程级单例，而 swift-testing 并发跑用例——**用到桩的 kind 必须
/// 走单条串行用例**（见 `urlStubKindsSequentially`）。用 `NSLock` 串行会在协作线程池
/// 上死锁：持锁线程占满 → URLSession 回调拿不到线程 → 全部挂起。
final class S20StubRegistry: @unchecked Sendable {
    struct Stub {
        var status: Int = 200
        var body: Data = Data()
        var contentType = "text/html; charset=utf-8"
        var failure: URLError?
    }

    struct Recorded {
        let method: String
        let host: String
        let path: String
        /// **解码后**的查询项（不投原始 URL 串：Dart 的 queryParameters 与 Swift 的
        /// queryItems 在 `+` / `%20` 上不完全一致，见规格 S20 §11）。
        let query: [String: String]
        let headerNames: [String]
        let authHeader: String?
        let hasUserAgent: Bool
        let body: JSONValue?
    }

    private let lock = NSLock()
    private var stubs: [String: [Stub]] = [:]
    private var recorded: [String: [Recorded]] = [:]

    /// 登记一个端点的响应（`stubs[authority]` 是队列，按调用序消费）。
    func enqueue(authority: String, _ stub: Stub) {
        lock.lock(); defer { lock.unlock() }
        stubs[authority, default: []].append(stub)
    }

    /// 取一个待回放的响应（按登记序消费）。
    func takeStub(for url: URL) -> Stub? {
        lock.lock(); defer { lock.unlock() }
        guard let key = authority(of: url), var queue = stubs[key], !queue.isEmpty else { return nil }
        let head = queue.removeFirst()
        stubs[key] = queue
        return head
    }

    func record(_ request: URLRequest, body: Data?) {
        guard let url = request.url else { return }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let entry = Recorded(
            method: request.httpMethod ?? "GET",
            host: url.host ?? "",
            path: url.path,
            query: query,
            headerNames: (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }.sorted(),
            authHeader: request.value(forHTTPHeaderField: "authorization")
                ?? request.value(forHTTPHeaderField: "x-api-key")
                ?? request.value(forHTTPHeaderField: "x-subscription-token"),
            hasUserAgent: request.value(forHTTPHeaderField: "user-agent") != nil,
            body: body.flatMap { try? JSONValue.parse($0) }
        )
        lock.lock(); defer { lock.unlock() }
        recorded[authority(of: url) ?? "", default: []].append(entry)
    }

    /// 登记**同一个**响应 `times` 次（一个用例常要连打同一端点多次）。
    func enqueue(authority: String, _ stub: Stub, times: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        for _ in 0..<max(1, times) { stubs[authority, default: []].append(stub) }
    }

    /// 诊断：打印某端点收到的请求。
    func debugDump(_ url: String) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let key = authority(of: URL(string: url) ?? URL(fileURLWithPath: "/")) else {
            return "no key"
        }
        return "\(recorded[key]?.count ?? 0) 条：" + (recorded[key] ?? []).map { entry in
            "\n  \(entry.method) \(entry.host)\(entry.path) headers=\(entry.headerNames) auth=\(entry.authHeader ?? "nil") body=\(String(describing: entry.body))"
        }.joined()
    }

    /// 某个端点收到的**第一个**请求的形状投影。
    func shape(of url: String) -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        guard let key = authority(of: URL(string: url) ?? URL(fileURLWithPath: "/")),
              let first = recorded[key]?.first else {
            return .object(["sent": .bool(false)])
        }
        // URLSession 会自动加 `content-length` / `accept-encoding` 等传输层头，
        // 来源的 `http` 客户端不会——头名列表要可比就得剔掉它们（值投影不受影响）。
        let transportHeaders: Set<String> = [
            "content-length", "accept-encoding", "connection", "host", "user-agent-default",
        ]
        var shape: [String: JSONValue] = [
            "sent": .bool(true),
            "method": .string(first.method),
            "host": .string(first.host),
            "path": .string(first.path),
            "headerNames": .array(
                first.headerNames.filter { !transportHeaders.contains($0) }.map { .string($0) }
            ),
        ]
        shape["query"] = .object(
            Dictionary(uniqueKeysWithValues: first.query.map { ($0.key, JSONValue.string($0.value)) })
        )
        if let auth = first.authHeader { shape["authHeader"] = .string(auth) }
        if first.hasUserAgent { shape["hasUserAgent"] = .bool(true) }
        if let body = first.body { shape["body"] = body }
        return .object(shape)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs = [:]
        recorded = [:]
    }

    private func authority(of url: URL) -> String? {
        guard let host = url.host else { return nil }
        return "\(host):\(url.port.map(String.init) ?? "")\(url.path)"
    }
}

/// 带桩的 `URLSession`。
func s20Session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [S20StubProtocol.self]
    return URLSession(configuration: configuration)
}

/// 读取用例里的响应描述（`{status, body}`）并登记到桩。
@discardableResult
func s20Stub(
    _ spec: [String: JSONValue],
    endpoint: String,
    times: Int = 1
) -> S20StubRegistry.Stub {
    var stub = S20StubRegistry.Stub()
    stub.status = Int(spec["status"]?.intValue ?? 200)
    stub.body = Data((spec["body"]?.stringValue ?? "").utf8)
    if let contentType = spec["contentType"]?.stringValue { stub.contentType = contentType }
    if case .some(.bool(true)) = spec["networkError"] { stub.failure = URLError(.notConnectedToInternet) }
    if let url = URL(string: endpoint), let host = url.host {
        S20StubProtocol.registry.enqueue(
            authority: "\(host):\(url.port.map(String.init) ?? "")\(url.path)", stub, times: times
        )
    }
    return stub
}

extension S20StubProtocol {
    /// 恒定失败的会话（超时 / 传输错误），用于文案断言。
    ///
    /// 走独立协议类而非注册表：这些用例不与 fixture 用例抢桩队列（也不该被它们的
    /// `reset()` 波及）。
    static func sessionFailing(_ error: URLError.Code) -> URLSession {
        S20FailingProtocol.nextError = error
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [S20FailingProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// 恒定失败的桩。
final class S20FailingProtocol: URLProtocol {
    nonisolated(unsafe) static var nextError: URLError.Code = .timedOut

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(Self.nextError))
    }
    override func stopLoading() {}
}
