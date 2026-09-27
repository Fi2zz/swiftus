import Foundation

// REASON: URLProtocol 桩必须跨线程共享 handler 与请求记录,属测试专用替身,
// 以 NSLock 显式同步(不涉及框架代码的 @unchecked Sendable 禁令)。
/// 拦截 URLSession 请求的测试桩:setHandler 预设响应,requests 回放生成的请求。
final class MockURLProtocol: URLProtocol {
    /// 被捕获的请求及其完整 body(URLSession 传输时会把 httpBody 挪入 httpBodyStream)。
    struct CapturedRequest {
        let request: URLRequest
        let body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var captured: [CapturedRequest] = []

    static var requests: [CapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static func setHandler(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        defer { lock.unlock() }
        captured = []
        self.handler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        do {
            let (response, data) = try handler!(request)
            Self.lock.lock()
            Self.captured.append(CapturedRequest(request: request, body: Self.readBody(of: request)))
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

/// 装配了 MockURLProtocol 的会话。
func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

/// 把 SSE 帧拼成响应体(帧间空行)。
func sseBody(_ frames: [String]) -> Data {
    Data(frames.map { "data: \($0)\n\n" }.joined().utf8)
}

/// 200 响应。
func httpOk() -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://mock.local")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
}
