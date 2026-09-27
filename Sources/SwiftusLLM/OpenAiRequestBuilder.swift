import SwiftusCore

/// 请求体构建：chat / responses 双形态载荷与 tools 投影（规格 S10 §3 / §4）。
extension OpenAiCompatibleProvider {
    /// 请求体：model + 形态载荷 + stream 字段 + tools 投影 + options 覆盖。
    /// 非流式签名也走流式端点，故 stream 字段恒下发（S10 §5）。
    func buildBody(_ request: LlmRequest) -> JSONValue {
        var body: [String: JSONValue] = ["model": .string(model)]
        applyStylePayload(&body, messages: request.messages)
        applyStreamFields(&body)
        applyTools(&body, tools: request.tools)
        applyOptions(&body, options: request.options)
        return .object(body)
    }

    private func applyStylePayload(_ body: inout [String: JSONValue], messages: [LlmMessage]) {
        guard responsesStyle else {
            body["messages"] = .array(messages.map(\.chatItem))
            return
        }
        body["input"] = .array(responsesInputItems(messages))
        body["store"] = .bool(false)
    }

    private func applyStreamFields(_ body: inout [String: JSONValue]) {
        body["stream"] = .bool(true)
        guard !responsesStyle else { return }
        body["stream_options"] = .object(["include_usage": .bool(true)])
    }

    private func applyTools(_ body: inout [String: JSONValue], tools: [JSONValue]?) {
        guard let tools, !tools.isEmpty else { return }
        body["tools"] = .array(tools.map(projectTool))
    }

    private func applyOptions(_ body: inout [String: JSONValue], options: [String: JSONValue]?) {
        guard let options else { return }
        for (key, value) in options {
            body[key] = value
        }
    }

    /// tools 投影：chat 形态包 function 字段，responses 形态扁平（白名单三键）。
    private func projectTool(_ tool: JSONValue) -> JSONValue {
        let name = tool["name"] ?? .null
        let description = tool["description"] ?? .null
        let parameters = tool["parameters"] ?? .null
        guard responsesStyle else {
            return .object([
                "type": .string("function"),
                "function": .object(["name": name, "description": description, "parameters": parameters]),
            ])
        }
        return .object([
            "type": .string("function"),
            "name": name,
            "description": description,
            "parameters": parameters,
        ])
    }

    /// Responses input 项：普通消息、助手工具调用、工具结果各自映射（规格 S10 §4）。
    private func responsesInputItems(_ messages: [LlmMessage]) -> [JSONValue] {
        var items: [JSONValue] = []
        for message in messages {
            if message.role == "tool" {
                items.append(functionCallOutput(message))
                continue
            }
            if !message.toolCalls.isEmpty {
                if !message.content.isEmpty { items.append(responsesMessageItem(message)) }
                message.toolCalls.forEach { items.append(functionCallItem($0)) }
                continue
            }
            items.append(responsesMessageItem(message))
        }
        return items
    }

    private func functionCallOutput(_ message: LlmMessage) -> JSONValue {
        .object([
            "type": .string("function_call_output"),
            "call_id": .string(message.toolCallId ?? ""),
            "output": .string(message.content),
        ])
    }

    private func functionCallItem(_ call: LlmToolCall) -> JSONValue {
        .object([
            "type": .string("function_call"),
            "call_id": .string(call.id),
            "name": .string(call.name),
            "arguments": .string(call.arguments),
        ])
    }

    /// Responses message 项：带 type=message；assistant 历史项另须 status=completed（Ark 强校验）。
    private func responsesMessageItem(_ message: LlmMessage) -> JSONValue {
        let assistant = message.role == "assistant"
        var item: [String: JSONValue] = [
            "type": .string("message"),
            "role": .string(message.role),
        ]
        if assistant { item["status"] = .string("completed") }
        item["content"] = .array(responsesContentParts(message, assistant: assistant))
        return .object(item)
    }

    private func responsesContentParts(_ message: LlmMessage, assistant: Bool) -> [JSONValue] {
        var parts: [JSONValue] = [
            .object([
                "type": .string(assistant ? "output_text" : "input_text"),
                "text": .string(message.content),
            ]),
        ]
        for image in message.images {
            parts.append(.object([
                "type": .string("input_image"),
                "image_url": .string(image.dataUrl),
            ]))
        }
        return parts
    }
}
