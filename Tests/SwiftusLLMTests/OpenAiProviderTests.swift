import Foundation
import SwiftusCore
import SwiftusCredentials
import SwiftusLLM
import Testing

@ContextTreeActor
func makeProvider(
    name: String = "mock",
    style: LlmApiStyle = .chat,
    configure: (inout OpenAiConfig) -> Void = { _ in }
) -> OpenAiCompatibleProvider {
    var config = OpenAiConfig(name: name, baseUrl: "https://mock.local/v1", model: "m1")
    config.apiKey = "sk-test"
    config.apiStyle = style
    configure(&config)
    return OpenAiCompatibleProvider(config: config, session: mockSession())
}

/// 规格 S10:OpenAI 兼容 wire 层端到端(经 MockURLProtocol 断言请求、驱动响应)。
/// MockURLProtocol 的 handler 是共享静态状态,本套件必须串行(其余套件不触碰该桩)。
@ContextTreeActor
@Suite("OpenAiCompatibleProvider wire 层", .serialized)
struct OpenAiProviderTests {
    @Test("chat 形态:请求体投影与 SSE 解析端到端")
    func chatEndToEnd() async throws {
        MockURLProtocol.setHandler { _ in
            (httpOk(), sseBody([
                #"{"choices":[{"delta":{"reasoning_content":"想"}}]}"#,
                #"{"choices":[{"delta":{"content":"你"}}]}"#,
                #"{"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}],"usage":{"total_tokens":3}}"#,
                "[DONE]",
            ]))
        }
        let provider = makeProvider()
        let result = try await provider.chat(LlmRequest(messages: [LlmMessage("user", "hi")]))
        #expect(result.content == "你好")
        #expect(result.reasoning == "想")
        #expect(result.usage["total_tokens"] == .int(3))
        #expect(result.provider == "mock")
        #expect(result.model == "m1")

        let captured = try #require(MockURLProtocol.requests.first)
        #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(captured.request.value(forHTTPHeaderField: "User-Agent") == kDefaultLlmUserAgent)
        let body = try JSONValue.parse(try #require(captured.body))
        #expect(body["model"] == .string("m1"))
        #expect(body["stream"] == .bool(true))
        #expect(body["stream_options"] == .object(["include_usage": .bool(true)]))
        #expect(body["messages"]?[0]?["content"] == .string("hi"))
        #expect(body["input"] == nil)
    }

    @Test("responses 形态:input 项映射与事件解析")
    func responsesEndToEnd() async throws {
        MockURLProtocol.setHandler { _ in
            (httpOk(), sseBody([
                #"{"type":"response.output_item.added","item":{"type":"function_call","id":"item1","call_id":"call_9","name":"search"}}"#,
                #"{"type":"response.function_call_arguments.delta","item_id":"item1","delta":"{\"q\":"}"#,
                #"{"type":"response.function_call_arguments.done","item_id":"item1","arguments":"{\"q\":\"swift\"}"}"#,
                #"{"type":"response.output_text.delta","delta":"答案"}"#,
                #"{"type":"response.completed","response":{"status":"completed","usage":{"total_tokens":7}}}"#,
            ]))
        }
        let provider = makeProvider(style: .responses)
        let toolCall = LlmToolCall(id: "call_9", name: "search", arguments: "{\"q\":\"swift\"}")
        let request = LlmRequest(messages: [
            LlmMessage("user", "查一下"),
            .toolCallRequest([toolCall]),
            .toolResult("call_9", "结果文本"),
        ])
        let result = try await provider.chat(request)
        #expect(result.content == "答案")
        #expect(result.usage["total_tokens"] == .int(7))
        #expect(try #require(result.toolCalls.first).id == "call_9")
        #expect(result.toolCalls[0].arguments == #"{"q":"swift"}"#)
        #expect(result.usage["total_tokens"] == .int(7))

        let body = try JSONValue.parse(try #require(MockURLProtocol.requests.first?.body))
        #expect(body["store"] == .bool(false))
        #expect(body["messages"] == nil)
        let input = try #require(body["input"]?.arrayValue)
        #expect(input.count == 3)
        #expect(input[0]["type"] == .string("message"))
        #expect(input[0]["content"]?[0]?["type"] == .string("input_text"))
        #expect(input[1]["type"] == .string("function_call"))
        #expect(input[1]["call_id"] == .string("call_9"))
        #expect(input[2]["type"] == .string("function_call_output"))
        #expect(input[2]["output"] == .string("结果文本"))
    }

    @Test("tools 投影:chat 包 function、responses 扁平,宿主字段不下发")
    func toolsProjection() async throws {
        MockURLProtocol.setHandler { _ in
            (httpOk(), sseBody([#"{"choices":[{"delta":{"content":"x"}}]}"#, "[DONE]"]))
        }
        let tools: [JSONValue] = [.object([
            "name": .string("search"),
            "description": .string("搜"),
            "parameters": .object(["type": .string("object")]),
            "host_field": .string("不下发"),
        ])]
        let chatProvider = makeProvider()
        _ = try await chatProvider.chat(LlmRequest(messages: [LlmMessage("user", "x")], tools: tools))
        var body = try JSONValue.parse(try #require(MockURLProtocol.requests.first?.body))
        #expect(body["tools"]?[0]?["function"]?["name"] == .string("search"))
        #expect(body["tools"]?[0]?["function"]?["host_field"] == nil)
        #expect(body["tools"]?[0]?["name"] == nil)

        MockURLProtocol.setHandler { _ in
            (httpOk(), sseBody([#"{"type":"response.completed","response":{"status":"completed"}}"#]))
        }
        let responsesProvider = makeProvider(style: .responses)
        _ = try await responsesProvider.chat(LlmRequest(messages: [LlmMessage("user", "x")], tools: tools))
        body = try JSONValue.parse(try #require(MockURLProtocol.requests.first?.body))
        #expect(body["tools"]?[0]?["name"] == .string("search"))
        #expect(body["tools"]?[0]?["function"] == nil)
    }

    @Test("chat 工具调用分片:按 index 累积,无名占位丢弃")
    func chatToolCallShards() async throws {
        MockURLProtocol.setHandler { _ in
            (httpOk(), sseBody([
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"search","arguments":""}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"q\":"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"swift\"}"}},{"index":1,"function":{"arguments":"{}"}}]}}]}"#,
                "[DONE]",
            ]))
        }
        let provider = makeProvider()
        let result = try await provider.chat(LlmRequest(messages: [LlmMessage("user", "x")]))
        #expect(try #require(result.toolCalls.first).id == "call_1")
        #expect(result.toolCalls[0].name == "search")
        #expect(result.toolCalls[0].arguments == #"{"q":"swift"}"#)
    }
}
