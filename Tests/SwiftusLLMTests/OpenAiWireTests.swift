import Foundation
import SwiftusCore
import SwiftusCredentials
import SwiftusLLM
import Testing

/// 规格 S10 §6 / §10 / §12:SSE 边界、错误形态、凭据联动。
/// 与主套件同一串行套件(extension 拆分,共享 .serialized)。
extension OpenAiProviderTests {
    @Test("SSE:注释行与非 data 字段忽略,单帧 JSON 可跨两行 data 拼接")
    func sseEdges() async throws {
        MockURLProtocol.setHandler { _ in
            let frame = "{\"choices\":[{\"delta\":"
                + "\ndata: {\"content\":\"多行\"}}]}"
            let raw = ": 注释\nevent: message\nid: 42\ndata: \(frame)\n\ndata: [DONE]\n"
            return (httpOk(), Data(raw.utf8))
        }
        let provider = makeProvider()
        let result = try await provider.chat(LlmRequest(messages: [LlmMessage("user", "x")]))
        #expect(result.content == "多行")
    }

    @Test("非 200:抛出带 statusCode 与 body 的 LlmException")
    func httpError() async {
        MockURLProtocol.setHandler { _ in
            (HTTPURLResponse(
                url: URL(string: "https://mock.local")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!, Data("rate limited".utf8))
        }
        let provider = makeProvider()
        do {
            _ = try await provider.chat(LlmRequest(messages: [LlmMessage("user", "x")]))
            Issue.record("应当抛出")
        } catch let error as LlmException {
            #expect(error.statusCode == 429)
            #expect(error.message == "rate limited")
        } catch {
            Issue.record("错误类型不对:\(error)")
        }
    }

    @Test("缺 API Key:消息含凭据键提示")
    func missingKey() async {
        let provider = OpenAiCompatibleProvider(
            config: {
                var config = OpenAiConfig(name: "c", baseUrl: "https://mock.local", model: "m")
                config.credentialKey = "ARK_API_KEY"
                return config
            }(),
            session: mockSession(),
            credentials: InMemoryCredentials()
        )
        do {
            _ = try await provider.chat(LlmRequest(messages: [LlmMessage("user", "x")]))
            Issue.record("应当抛出")
        } catch let error as LlmException {
            #expect(error.message == "缺少 API Key（凭据键：ARK_API_KEY 未配置）")
        } catch {
            Issue.record("错误类型不对:\(error)")
        }
    }

    @Test("凭据变更推送驱动 Key 就地轮换,close 取消订阅")
    func keyRotation() async throws {
        MockURLProtocol.setHandler { _ in
            (httpOk(), sseBody([#"{"choices":[{"delta":{"content":"x"}}]}"#, "[DONE]"]))
        }
        let credentials = InMemoryCredentials(initial: ["ARK_API_KEY": "sk-old"])
        var config = OpenAiConfig(name: "c", baseUrl: "https://mock.local", model: "m")
        config.credentialKey = "ARK_API_KEY"
        let provider = OpenAiCompatibleProvider(config: config, session: mockSession(), credentials: credentials)
        #expect(provider.apiKey == "sk-old")
        try await credentials.update("ARK_API_KEY", "sk-new")
        #expect(provider.apiKey == "sk-new")
        _ = try await provider.chat(LlmRequest(messages: [LlmMessage("user", "x")]))
        #expect(MockURLProtocol.requests.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-new")
        provider.close()
        try await credentials.update("ARK_API_KEY", "sk-ignored")
        #expect(provider.apiKey == "sk-new")
    }
}
