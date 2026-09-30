import Foundation
import SwiftusCore

/// 一条 SSE 事件（规格 S11 §4）。
public struct SseEvent: Sendable, Equatable {
    /// `event:` 字段；缺省时由上层按 `message` 语义处理。
    public let event: String?
    /// `data:` 字段（多行以 `\n` 拼接）。
    public let data: String
    /// `id:` 字段。
    public let id: String?

    public init(event: String? = nil, data: String = "", id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

extension SseEvent: CustomStringConvertible {
    public var description: String {
        "SseEvent(\(event ?? "message"): \(data.count) 字节)"
    }
}

/// Server-Sent Events 解析：`text/event-stream` → 事件流（规格 S11 §4）。
///
/// 纯线协议解析，不依赖 MCP。按 SSE 规范累积 `event:` / `data:` / `id:` 字段，
/// 遇空行派发；`:` 开头的注释行忽略；多行 `data:` 用换行拼接。
///
/// **字节级而非行级**：URLSession 的 `AsyncBytes` 是任意切分的字节流，半行、
/// 半字段、被切断的多字节字符都必须能重组（fixtures 逐条覆盖这三种切分），
/// 因此缓冲的是未解码的字节、只在完整行处切分。
public struct McpSseParser {
    /// 跨 chunk 累积的状态（未派发的字段 + 半行残留）。
    public struct State {
        var dataLines: [String] = []
        var event: String?
        var id: String?
        /// 已收到 data 字段（哪怕值是空串——「无冒号视为空值」也算）。
        var sawData = false
        /// 尚未切出完整行的残留字节。
        var pendingBytes: [UInt8] = []

        public init() {}
    }

    public init() {}

    /// 吃一段字节，返回本次派发的全部事件。
    ///
    /// 切分规则：`\n` 或 `\r\n` 结束一行；块**末尾**的残行留在缓冲里等下一段
    /// （chunk 边界处的半行不丢）。
    public mutating func consume(_ bytes: [UInt8], state: inout State) -> [SseEvent] {
        var events: [SseEvent] = []
        var lineBytes = state.pendingBytes
        state.pendingBytes = []
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                // 行尾的 \r 属于 CRLF，剥掉。
                if lineBytes.last == UInt8(ascii: "\r") { lineBytes.removeLast() }
                if let event = consumeLine(String(decoding: lineBytes, as: UTF8.self), state: &state) {
                    events.append(event)
                }
                lineBytes.removeAll(keepingCapacity: true)
            } else {
                lineBytes.append(byte)
            }
        }
        state.pendingBytes = lineBytes
        return events
    }

    /// 流结束：冲掉残留的半行（EOF 时未派发的 `data` 也派发一次）。
    public mutating func finish(_ state: inout State) -> [SseEvent] {
        var events: [SseEvent] = []
        if !state.pendingBytes.isEmpty {
            var lineBytes = state.pendingBytes
            state.pendingBytes = []
            if lineBytes.last == UInt8(ascii: "\r") { lineBytes.removeLast() }
            if let event = consumeLine(String(decoding: lineBytes, as: UTF8.self), state: &state) {
                events.append(event)
            }
        }
        if let event = dispatch(state: &state) {
            events.append(event)
        }
        return events
    }

    /// 吃一行，返回该行派发出的完整事件（没有则 nil）。
    private func consumeLine(_ line: String, state: inout State) -> SseEvent? {
        // 空行 = 派发。
        if line.isEmpty { return dispatch(state: &state) }
        // `:` 开头的注释行忽略。
        if line.hasPrefix(":") { return nil }

        guard let colon = line.firstIndex(of: ":") else {
            // 无冒号：字段名就是整行，值是空串。
            apply(field: String(line), value: "", state: &state)
            return nil
        }
        let field = String(line[line.startIndex..<colon])
        var value = String(line[line.index(after: colon)...])
        // 冒号后**恰好一个**前导空格被剥掉，其余保留。
        if value.hasPrefix(" ") { value.removeFirst() }
        apply(field: field, value: value, state: &state)
        return nil
    }

    private func apply(field: String, value: String, state: inout State) {
        switch field {
        case "event": state.event = value
        case "data": state.dataLines.append(value); state.sawData = true
        case "id": state.id = value
        default: break // 未知字段按 SSE 规范忽略
        }
    }

    /// 派发：累积的 `data` 非空才产出事件（空 data 的块不派发），派发后清空字段。
    private func dispatch(state: inout State) -> SseEvent? {
        defer {
            state.dataLines.removeAll(keepingCapacity: true)
            state.event = nil
            state.id = nil
            state.sawData = false
        }
        guard state.sawData else { return nil }
        let data = state.dataLines.joined(separator: "\n")
        guard !data.isEmpty else { return nil }
        return SseEvent(event: state.event, data: data, id: state.id)
    }
}

/// 把一段完整的 `text/event-stream` 载荷解析成事件（一次性、无流）。
///
/// 用于 HTTP 传输的**单包**正文（服务端选择流式形态时正文里可能有多条消息）。
public func parseMcpSsePayload(_ payload: String) -> [SseEvent] {
    var parser = McpSseParser()
    var state = McpSseParser.State()
    var events = parser.consume(Array(payload.utf8), state: &state)
    events.append(contentsOf: parser.finish(&state))
    return events
}
