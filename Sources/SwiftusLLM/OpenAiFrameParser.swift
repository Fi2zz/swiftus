import SwiftusCore

/// 帧解析：SSE 帧 JSON → 流式事件（规格 S10 §7 / §8）。
extension OpenAiCompatibleProvider {
    /// 单帧 → 事件列表；按形态分派。
    func frameEvents(_ frame: JSONValue, state: StreamState) throws -> [LlmStreamEvent] {
        guard responsesStyle else { return chatFrameEvents(frame, state: state) }
        return try responsesFrameEvents(frame, state: state)
    }

    /// Chat 帧：usage 覆盖 + choices[0].delta 增量（规格 S10 §7）。
    private func chatFrameEvents(_ frame: JSONValue, state: StreamState) -> [LlmStreamEvent] {
        if let usage = frame["usage"]?.objectValue { state.usage = usage }
        guard let choice = frame["choices"]?[0]?.objectValue else { return [] }
        if let reason = choice["finish_reason"]?.stringValue { state.finishReason = reason }
        let delta = choice["delta"] ?? .null
        accumulateChatToolCalls(delta["tool_calls"], state: state)
        return chatDeltaEvents(delta)
    }

    private func chatDeltaEvents(_ delta: JSONValue) -> [LlmStreamEvent] {
        var events: [LlmStreamEvent] = []
        if let reasoning = delta["reasoning_content"]?.stringValue, !reasoning.isEmpty {
            events.append(.reasoningDelta(reasoning))
        }
        if let content = delta["content"]?.stringValue, !content.isEmpty {
            events.append(.textDelta(content))
        }
        return events
    }

    /// Chat 的 delta.tool_calls：按 index 累积 id / name / arguments 分片。
    private func accumulateChatToolCalls(_ rawCalls: JSONValue?, state: StreamState) {
        guard let calls = rawCalls?.arrayValue else { return }
        for case let .object(rawCall) in calls {
            let index = rawCall["index"]?.intValue ?? state.chatBuilderCount
            applyChatShard(rawCall, to: state.chatBuilder(index: index))
        }
    }

    private func applyChatShard(_ rawCall: [String: JSONValue], to builder: ToolCallBuilder) {
        if let id = rawCall["id"]?.stringValue, !id.isEmpty { builder.id = id }
        guard let function = rawCall["function"]?.objectValue else { return }
        if let name = function["name"]?.stringValue, !name.isEmpty { builder.name = name }
        builder.addArguments(function["arguments"])
    }

    // REASON: Responses 事件 type 分派为协议固定形态，属静态映射表例外（全局 AGENTS.md §6）。
    /// Responses 帧：按事件 type 分派（规格 S10 §8）。
    private func responsesFrameEvents(_ frame: JSONValue, state: StreamState) throws -> [LlmStreamEvent] {
        switch frame["type"]?.stringValue ?? "" {
        case "response.output_text.delta":
            return deltaEvent(frame["delta"], make: LlmStreamEvent.textDelta)
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            return deltaEvent(frame["delta"], make: LlmStreamEvent.reasoningDelta)
        case "response.output_item.added", "response.output_item.done":
            accumulateResponsesItem(frame["item"], state: state)
            return []
        case "response.function_call_arguments.delta":
            state.responsesBuilder(itemId: frame["item_id"]?.stringValue ?? "")
                .addArguments(frame["delta"])
            return []
        case "response.function_call_arguments.done":
            state.responsesBuilder(itemId: frame["item_id"]?.stringValue ?? "")
                .setArguments(frame["arguments"])
            return []
        case "response.completed", "response.incomplete":
            applyResponsesTerminal(frame, state: state)
            return []
        case "response.failed":
            throw responsesFailure(frame)
        default:
            return []
        }
    }

    private func deltaEvent(_ delta: JSONValue?, make: (String) -> LlmStreamEvent) -> [LlmStreamEvent] {
        guard let text = delta?.stringValue, !text.isEmpty else { return [] }
        return [make(text)]
    }

    /// completed / incomplete：usage 覆盖；incomplete 的 finishReason 为 'length'。
    private func applyResponsesTerminal(_ frame: JSONValue, state: StreamState) {
        let response = frame["response"]?.objectValue ?? [:]
        if let usage = response["usage"]?.objectValue { state.usage = usage }
        guard frame["type"]?.stringValue == "response.incomplete" else {
            state.finishReason = response["status"]?.stringValue ?? "completed"
            return
        }
        state.finishReason = "length"
    }

    private func responsesFailure(_ frame: JSONValue) -> LlmException {
        let message = frame["response"]?["error"]?["message"]?.stringValue ?? "unknown"
        return LlmException(name, "流式响应失败：\(message)")
    }

    /// Responses 输出项：function_call 项收 call_id / name / arguments（done 帧为权威完整值）。
    private func accumulateResponsesItem(_ rawItem: JSONValue?, state: StreamState) {
        guard let item = rawItem?.objectValue, item["type"]?.stringValue == "function_call" else { return }
        let builder = state.responsesBuilder(itemId: item["id"]?.stringValue ?? "")
        if let callId = item["call_id"]?.stringValue, !callId.isEmpty { builder.id = callId }
        if let name = item["name"]?.stringValue, !name.isEmpty { builder.name = name }
        builder.setArguments(item["arguments"])
    }
}
