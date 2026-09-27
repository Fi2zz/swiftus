import SwiftusCore
import SwiftusLLM
import Testing

private func sampleRequest() -> LlmRequest {
    LlmRequest(messages: [LlmMessage("user", "hi")])
}

/// 规格 S10 §11:FallbackLlm 顺序回退与流式回退边界。
@ContextTreeActor
@Suite("FallbackLlm 回退链")
struct FallbackLlmTests {
    @Test("chat:首个成功即返回;失败回退下一个")
    func chatFallback() async throws {
        let first = ScriptedProvider(name: "p1")
        first.chatHandler = { _ in throw LlmException("p1", "炸了") }
        let second = ScriptedProvider(name: "p2")
        second.chatHandler = { _ in LlmResult(content: "ok2", provider: "p2", model: "m") }
        let fallback = FallbackLlm([first, second])
        let result = try await fallback.chat(sampleRequest())
        #expect(result.content == "ok2")
    }

    @Test("chat:全部失败时汇总各提供商错误")
    func chatAggregates() async {
        let first = ScriptedProvider(name: "p1")
        first.chatHandler = { _ in throw LlmException("p1", "炸了") }
        let fallback = FallbackLlm([first])
        do {
            _ = try await fallback.chat(sampleRequest())
            Issue.record("应当抛出汇总错误")
        } catch let error as LlmException {
            #expect(error.provider == "fallback")
            #expect(error.message.contains("所有提供商均失败"))
            #expect(error.message.contains("p1: 炸了"))
        } catch {
            Issue.record("错误类型不对:\(error)")
        }
    }

    @Test("chatStream:未产出事件前可回退")
    func streamFallbackBeforeEmit() async throws {
        let first = ScriptedProvider(name: "p1")
        first.streamHandler = { _, _ in throw LlmException("p1", "连不上") }
        let second = ScriptedProvider(name: "p2")
        second.streamHandler = { _, continuation in continuation.yield(.textDelta("ok")) }
        let fallback = FallbackLlm([first, second])
        var events: [LlmStreamEvent] = []
        for try await event in fallback.chatStream(sampleRequest()) {
            events.append(event)
        }
        #expect(events == [.textDelta("ok")])
    }

    @Test("chatStream:已产出事件后失败直接上抛,不再回退")
    func streamRethrowAfterEmit() async {
        let first = ScriptedProvider(name: "p1")
        first.streamHandler = { _, continuation in
            continuation.yield(.textDelta("半句"))
            throw LlmException("p1", "断了")
        }
        let fallback = FallbackLlm([first, ScriptedProvider(name: "p2")])
        var received: [LlmStreamEvent] = []
        do {
            for try await event in fallback.chatStream(sampleRequest()) {
                received.append(event)
            }
            Issue.record("应当上抛")
        } catch let error as LlmException {
            #expect(error.message == "断了")
        } catch {
            Issue.record("错误类型不对:\(error)")
        }
        #expect(received == [.textDelta("半句")])
    }

    @Test("close 级联关闭全部 provider")
    func closeCascade() {
        let first = ScriptedProvider(name: "p1")
        let second = ScriptedProvider(name: "p2")
        FallbackLlm([first, second]).close()
        #expect(first.closed)
        #expect(second.closed)
    }
}

/// 规格 S10 §5:streamChatResult 累积语义与空流回退。
@ContextTreeActor
@Suite("streamChatResult 流式累积")
struct StreamChatResultTests {
    @Test("累积正文 / 思考 / done 字段,onEvent 透传")
    func accumulates() async throws {
        let provider = ScriptedProvider(name: "p")
        provider.streamHandler = { _, continuation in
            continuation.yield(.textDelta("你"))
            continuation.yield(.textDelta("好"))
            continuation.yield(.reasoningDelta("想"))
            var done = LlmStreamDone()
            done.model = "m1"
            done.usage = ["total_tokens": .int(9)]
            done.toolCalls = [LlmToolCall(id: "c", name: "search")]
            continuation.yield(.done(done))
        }
        var seen = 0
        let result = try await streamChatResult(provider, sampleRequest()) { _ in seen += 1 }
        #expect(result.content == "你好")
        #expect(result.reasoning == "想")
        #expect(result.model == "m1")
        #expect(result.usage["total_tokens"] == .int(9))
        #expect(result.toolCalls.count == 1)
        #expect(seen == 4)
    }

    @Test("空流回退 chat()")
    func emptyStreamFallsBack() async throws {
        let provider = ScriptedProvider(name: "p")
        provider.chatHandler = { _ in LlmResult(content: "直连", provider: "p", model: "m") }
        let result = try await streamChatResult(provider, sampleRequest())
        #expect(result.content == "直连")
    }
}
