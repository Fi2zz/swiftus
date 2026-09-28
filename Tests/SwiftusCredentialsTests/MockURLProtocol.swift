import Foundation
import SwiftusCredentials

// REASON: URLProtocol 桩必须跨线程共享 handler 与请求记录,属测试专用替身,
// 以 NSLock 显式同步(不涉及框架代码的 @unchecked Sendable 禁令)。
///
/// **按 authority（host:port）分桶**：swift-testing 的用例并发执行，全局单一
/// handler 会互相串台（A 用例的 403 响应可能喂给 B 用例）。故 handler 注册表与
/// 请求记录都按 authority 隔离；authority 取自 fixture 声明的地址，因此
/// `127.0.0.1:8200` 与 `127.0.0.1:4566` 互不干扰，无需改动 fixture 的地址。
final class MockURLProtocol: URLProtocol {
    struct CapturedRequest {
        let request: URLRequest
        let body: Data?
    }

    private struct Bucket {
        var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        var captured: [CapturedRequest] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var buckets: [String: Bucket] = [:]

    /// 某 authority 上被拦截的请求（按发生顺序）。
    static func requests(authority: String) -> [CapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return buckets[authority]?.captured ?? []
    }

    /// 某 authority 上最近一次被拦截的请求。
    static func lastRequest(authority: String) -> CapturedRequest? {
        requests(authority: authority).last
    }

    static func setHandler(
        authority: String,
        status: Int = 200,
        body: String = "{}",
        networkError: Bool = false
    ) {
        lock.lock()
        defer { lock.unlock() }
        var bucket = buckets[authority] ?? Bucket()
        bucket.handler = { request in
            if networkError { throw MockNetworkError() }
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://\(authority)")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["content-type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        bucket.captured = []
        buckets[authority] = bucket
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let key = authority(of: request.url) else { return false }
        return buckets[key]?.handler != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let key = authority(of: request.url) ?? ""
        let handler = Self.buckets[key]?.handler
        Self.lock.unlock()
        do {
            let (response, data) = try handler!(request)
            Self.lock.lock()
            Self.buckets[key]?.captured.append(
                CapturedRequest(request: request, body: Self.readBody(of: request))
            )
            Self.lock.unlock()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(contentsOf: buffer[..<read])
        }
        return data
    }
}

/// URL 的 authority（host[:port]）——桩的分桶键。
func authority(of url: URL?) -> String? {
    guard let url, let host = url.host else { return nil }
    if let port = url.port { return "\(host):\(port)" }
    return host
}

/// 装配了 MockURLProtocol 的会话。
func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

/// 网络层失败的替身。
struct MockNetworkError: Error, CustomStringConvertible {
    let description = "The network connection was lost."
}

/// 受控等待器：测试里手动推进周期刷新的时间（规格 S12 §8 的时间缝）。
final class ManualRefreshClock: RefreshClock, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(interval: TimeInterval, resumed: @Sendable () -> Void)] = []
    private(set) var waits: [TimeInterval] = []
    private var cancelled = false

    /// 等待者数量（挂起中的周期任务数）。
    var pending: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func wait(_ interval: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            waits.append(interval)
            waiters.append((interval, {
                continuation.resume()
            }))
            lock.unlock()
        }
    }

    /// 放行最早的一个等待者（模拟时间到点）。
    func advance() {
        lock.lock()
        let next = waiters.isEmpty ? nil : waiters.removeFirst()
        lock.unlock()
        next?.resumed()
    }

    /// 放行全部等待者（至多 times 次）。
    func advanceAll(_ times: Int = 8) {
        for _ in 0..<times {
            lock.lock()
            let has = !waiters.isEmpty
            lock.unlock()
            if !has { return }
            advance()
        }
    }

    /// 调度器 close 时调用：立刻放行全部挂起的等待（否则 continuation 会一直挂着）。
    func cancelPendingWaits() {
        lock.lock()
        cancelled = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending {
            waiter.resumed()
        }
    }
}
