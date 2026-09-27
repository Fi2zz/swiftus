import Foundation
import SwiftusCore
import SwiftusCredentials

/// LLM 请求的默认 User-Agent。
public let kDefaultLlmUserAgent = "ConatusCode/0.16"

/// OpenAiCompatibleProvider 的装配参数。
public struct OpenAiConfig: Sendable {
    public var name: String
    public var baseUrl: String
    public var model: String

    /// 凭据服务里对应的键名（如 `ARK_API_KEY`）；为空表示不联动凭据。
    public var credentialKey = ""

    /// 显式 API Key；为空时按凭据服务解析。
    public var apiKey: String?

    public var apiStyle: LlmApiStyle = .chat

    /// 请求携带的 User-Agent（可伪装成其他 harness 客户端）。
    public var userAgent = kDefaultLlmUserAgent

    public var timeout: TimeInterval = 60

    public init(name: String, baseUrl: String, model: String) {
        self.name = name
        self.baseUrl = baseUrl
        self.model = model
    }
}

/// 通用 OpenAI 兼容提供商：Chat Completions / Responses 双形态的 wire 层（规格 S10）。
///
/// 凭据联动（S10 §12）：构造期按「显式 apiKey → 凭据服务」解析；之后由凭据
/// 变更推送就地轮换（不重建 HTTP 客户端）；close 取消订阅。
@ContextTreeActor
public final class OpenAiCompatibleProvider: LlmProvider {
    public let name: String
    public let baseUrl: String
    public let model: String
    public let credentialKey: String
    public let apiStyle: LlmApiStyle
    public let userAgent: String
    public let timeout: TimeInterval

    /// 当前 API Key；由凭据变更推送就地轮换。
    public private(set) var apiKey: String

    let session: URLSession
    private var credentialsToken: (source: any Credentials, token: Int)?

    public init(config: OpenAiConfig, session: URLSession = .shared, credentials: (any Credentials)? = nil) {
        name = config.name
        baseUrl = config.baseUrl
        model = config.model
        credentialKey = config.credentialKey
        apiStyle = config.apiStyle
        userAgent = config.userAgent
        timeout = config.timeout
        self.session = session
        apiKey = config.apiKey ?? credentials?.get(config.credentialKey)?.value ?? ""
        watchCredentials(credentials)
    }

    var responsesStyle: Bool {
        apiStyle == .responses
    }

    var headers: [String: String] {
        [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(apiKey)",
            "User-Agent": userAgent,
        ]
    }

    /// 非流式签名，实际走流式端点（规格 S10 §5）。
    public func chat(_ request: LlmRequest) async throws -> LlmResult {
        try await streamChatResult(self, request)
    }

    public func chatStream(_ request: LlmRequest) -> AsyncThrowingStream<LlmStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await driveStream(request, continuation: continuation) }
        }
    }

    /// 释放：取消凭据变更订阅。
    public func close() {
        guard let (source, token) = credentialsToken else { return }
        source.removeChangeListener(token)
        credentialsToken = nil
    }

    private func watchCredentials(_ credentials: (any Credentials)?) {
        guard let credentials, !credentialKey.isEmpty else { return }
        let token = credentials.addChangeListener { [weak self] credential in
            guard let self, credential.key == self.credentialKey else { return }
            guard !credential.expired() else { return }
            self.apiKey = credential.value
        }
        credentialsToken = (credentials, token)
    }

    private func requireKey() throws {
        guard apiKey.isEmpty else { return }
        let hint = credentialKey.isEmpty ? "缺少 API Key" : "缺少 API Key（凭据键：\(credentialKey) 未配置）"
        throw LlmException(name, hint)
    }

    private func driveStream(
        _ request: LlmRequest,
        continuation: AsyncThrowingStream<LlmStreamEvent, Error>.Continuation
    ) async {
        do {
            try requireKey()
            let (bytes, response) = try await session.bytes(for: buildUrlRequest(request))
            try await validateResponse(response, bytes: bytes)
            let state = StreamState()
            for try await payload in ssePayloads(bytes: bytes) {
                guard let frame = decodeFrame(payload) else { continue }
                for event in try frameEvents(frame, state: state) {
                    continuation.yield(event)
                }
            }
            continuation.yield(.done(state.terminal(provider: name, model: model)))
            continuation.finish()
        } catch {
            continuation.finish(throwing: mapTransportError(error))
        }
    }

    private func buildUrlRequest(_ request: LlmRequest) throws -> URLRequest {
        let path = responsesStyle ? "responses" : "chat/completions"
        guard let url = URL(string: "\(baseUrl)/\(path)") else {
            throw LlmException(name, "非法端点：\(baseUrl)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        for (field, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = try buildBody(request).jsonData()
        return urlRequest
    }

    private func validateResponse(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        throw LlmException(name, String(decoding: data, as: UTF8.self), statusCode: http.statusCode)
    }

    private func mapTransportError(_ error: any Error) -> any Error {
        guard let urlError = error as? URLError else { return error }
        if urlError.code == .timedOut {
            return LlmException(name, "请求超时（\(Int(timeout))s）")
        }
        return LlmException(name, "网络错误：\(urlError.localizedDescription)")
    }
}
