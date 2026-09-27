import Foundation
import SwiftusCore

/// 流式累积状态：用量、结束原因与工具调用分片可能晚于增量到达，收尾统一产出。
final class StreamState {
    var usage: [String: JSONValue] = [:]
    var finishReason: String?

    /// Chat Completions：按 tool_calls[].index 累积。
    private var chatBuilders: [ToolCallBuilder] = []

    /// Responses：按输出项 id 累积。
    private var responsesBuilders: [String: ToolCallBuilder] = [:]

    var chatBuilderCount: Int {
        chatBuilders.count
    }

    func chatBuilder(index: Int) -> ToolCallBuilder {
        while chatBuilders.count <= index {
            chatBuilders.append(ToolCallBuilder())
        }
        return chatBuilders[index]
    }

    func responsesBuilder(itemId: String) -> ToolCallBuilder {
        if let existing = responsesBuilders[itemId] { return existing }
        let created = ToolCallBuilder()
        responsesBuilders[itemId] = created
        return created
    }

    /// 汇总已完成的工具调用；丢弃只收到分片、始终无名的占位项（规格 S10 §9）。
    func buildToolCalls() -> [LlmToolCall] {
        (chatBuilders + responsesBuilders.values)
            .map { $0.build() }
            .filter { !$0.name.isEmpty }
    }

    func terminal(provider: String, model: String) -> LlmStreamDone {
        var done = LlmStreamDone()
        done.usage = usage
        done.finishReason = finishReason
        done.toolCalls = buildToolCalls()
        done.provider = provider
        done.model = model
        return done
    }
}

/// 流式工具调用分片累积器：id / name 一次性到达，arguments 为 JSON 分片。
final class ToolCallBuilder {
    var id = ""
    var name = ""
    private var arguments = ""

    /// 追加 arguments 分片；非字符串（已解析对象）按 JSON 编码。
    func addArguments(_ chunk: JSONValue?) {
        guard let chunk else { return }
        if let text = chunk.stringValue {
            guard !text.isEmpty else { return }
            arguments += text
            return
        }
        if let data = try? chunk.jsonData() {
            arguments += String(decoding: data, as: UTF8.self)
        }
    }

    /// 以完整 arguments 覆盖；空串忽略（终帧缺省时不抹掉已累积分片）。
    func setArguments(_ complete: JSONValue?) {
        guard let text = complete?.stringValue, !text.isEmpty else { return }
        arguments = text
    }

    func build() -> LlmToolCall {
        LlmToolCall(id: id, name: name, arguments: arguments.isEmpty ? "{}" : arguments)
    }
}

/// 解析一帧 SSE 载荷为 JSON 对象；非法 JSON 或非对象返回 nil。
func decodeFrame(_ payload: String) -> JSONValue? {
    guard let value = try? JSONValue.parse(Data(payload.utf8)) else { return nil }
    guard case .object = value else { return nil }
    return value
}

/// 响应字节流 → SSE data: 载荷序列（规格 S10 §6；坑 #4）。
///
/// 不依赖按行到达：字节级跨块 UTF-8 解码，行边界自行识别；
/// 空行成帧、多行 data 拼接、注释行忽略、[DONE] 终止（终止前冲刷已攒帧）。
func ssePayloads(bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                try await foldSseBytes(bytes: bytes, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

private func foldSseBytes(
    bytes: URLSession.AsyncBytes,
    continuation: AsyncThrowingStream<String, Error>.Continuation
) async throws {
    let folder = SseFolder()
    for try await byte in bytes {
        folder.consume(byte, continuation: continuation)
        guard !folder.terminated else { return }
    }
    folder.finish(continuation: continuation)
}

/// SSE 折叠器：逐字节喂入，行尾成行、空行成帧（规格 S10 §6）。
/// 0x0A 不会出现在多字节 UTF-8 序列内，按字节切块安全（坑 #4）。
final class SseFolder {
    /// [DONE] 是否已终止。
    private(set) var terminated = false

    private var lineBytes: [UInt8] = []
    private var pending = ""

    /// 喂入一个字节；0x0A 触发成行。已终止后忽略输入。
    func consume(_ byte: UInt8, continuation: AsyncThrowingStream<String, Error>.Continuation) {
        guard !terminated else { return }
        guard byte != 0x0A else {
            endLine(continuation: continuation)
            return
        }
        lineBytes.append(byte)
    }

    /// 流尾收尾：处理残留行并冲刷已攒帧。
    func finish(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        endLine(continuation: continuation)
        flushPending(continuation: continuation)
    }

    private func endLine(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        let trimmed = trimRight(String(decoding: lineBytes, as: UTF8.self))
        lineBytes.removeAll(keepingCapacity: true)
        guard !trimmed.isEmpty else {
            flushPending(continuation: continuation)
            return
        }
        guard !trimmed.hasPrefix(":") else { return }
        guard trimmed.hasPrefix("data:") else { return }
        appendPayload(trimLeft(String(trimmed.dropFirst(5))), continuation: continuation)
    }

    private func appendPayload(
        _ payload: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        guard payload != "[DONE]" else {
            flushPending(continuation: continuation)
            terminated = true
            return
        }
        pending += payload + "\n"
    }

    private func flushPending(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        let frame = trimRight(pending)
        pending = ""
        guard !frame.isEmpty else { return }
        continuation.yield(frame)
    }
}

private func trimRight(_ text: String) -> String {
    var result = text
    while let last = result.last, last.isWhitespace {
        result.removeLast()
    }
    return result
}

private func trimLeft(_ text: String) -> String {
    var result = text
    while let first = result.first, first.isWhitespace {
        result.removeFirst()
    }
    return result
}

