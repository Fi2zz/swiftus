import SwiftusCore
import SwiftusLLM
import Testing

/// 规格 S10 §2:消息与工具调用的 JSON 投影。
@Suite("LLM 消息与类型")
struct LlmTypesTests {
    @Test("chatItem:纯文本消息")
    func plainMessage() {
        let item = LlmMessage("user", "你好").chatItem
        #expect(item == .object(["role": .string("user"), "content": .string("你好")]))
    }

    @Test("chatItem:工具结果消息带 tool_call_id")
    func toolResultMessage() {
        let item = LlmMessage.toolResult("call_1", "结果").chatItem
        #expect(item["tool_call_id"] == .string("call_1"))
        #expect(item["role"] == .string("tool"))
    }

    @Test("chatItem:助手工具调用投影")
    func toolCallsMessage() {
        let call = LlmToolCall(id: "c1", name: "search", arguments: "{\"q\":\"x\"}")
        let item = LlmMessage.toolCallRequest([call]).chatItem
        #expect(item["tool_calls"]?[0]?["function"]?["name"] == .string("search"))
        #expect(item["tool_calls"]?[0]?["type"] == .string("function"))
    }

    @Test("chatItem:多模态内容为分段数组")
    func multimodalMessage() {
        var message = LlmMessage("user", "看图")
        message.images = [LlmImage(mimeType: "image/png", base64Data: "AA==")]
        let item = message.chatItem
        #expect(item["content"]?[0]?["type"] == .string("text"))
        #expect(item["content"]?[1]?["image_url"]?["url"] == .string("data:image/png;base64,AA=="))
    }
}
