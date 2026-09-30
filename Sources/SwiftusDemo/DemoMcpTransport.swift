import Foundation
import SwiftusCore
import SwiftusMCP

/// Demo 用的进程内 MCP server（不拉真子进程、不连网络）。
///
/// 目的：让离线 Demo 能把「MCP server 的工具进本地工具表并被模型调用」这条链路
/// 整条跑通——客户端握手、发现工具、注册适配器、执行调用、结果回填，一个不少。
/// 真实 server 用 `StdioTransport` / `HttpTransport` / `SseTransport`，语义与本替身
/// 完全一致（同一个 `McpClient` 协议面）。
@ContextTreeActor
public final class DemoMcpTransport: McpTransport {
    private let sink = McpMessageSink()
    private let diagnostics = McpDiagnostics()

    public init() {}

    public func connect() async throws {}

    public func disconnect() async {
        sink.finish()
        diagnostics.dispose()
    }

    public func messages() -> AsyncStream<McpTransportEvent> {
        sink.stream()
    }

    @discardableResult
    public func observeDiagnostics(_ body: @escaping @Sendable (String) -> Void) -> Int {
        diagnostics.observe(body)
    }

    public func send(_ message: McpMessage) async throws {
        guard let method = message.method, let id = message.id else { return }
        // 通知单向上行，不回响应。
        switch method {
        case "initialize":
            replyResult(id: id, [
                "protocolVersion": .string(kMcpProtocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("demo"), "version": .string("0.0.1")]),
            ])
        case "tools/list":
            replyResult(id: id, [
                "tools": .array([
                    .object([
                        "name": .string("shout"),
                        "description": .string("把文本转成大写并加感叹号（演示用的 MCP 工具）"),
                        // 只读工具 → 风险 low，不必审批。
                        "annotations": .object(["readOnlyHint": .bool(true)]),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object(["text": .object(["type": .string("string")])]),
                            "required": .array([.string("text")]),
                        ]),
                    ]),
                ]),
            ])
        case "tools/call":
            let arguments = message.params?["arguments"]?.objectValue ?? [:]
            let text = arguments["text"]?.stringValue ?? ""
            replyResult(id: id, [
                "content": .array([
                    .object(["type": .string("text"), "text": .string("\(text.uppercased())!")]),
                ]),
                "structuredContent": .object(["length": .int(Int64(text.count))]),
            ])
        default:
            replyError(id: id, code: -32601, message: "方法不存在")
        }
    }

    private func replyResult(id: JSONValue, _ result: [String: JSONValue]) {
        sink.emit(McpMessage(json: ["jsonrpc": .string("2.0"), "id": id, "result": .object(result)]))
    }

    private func replyError(id: JSONValue, code: Int, message: String) {
        sink.emit(McpMessage(json: [
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .int(Int64(code)), "message": .string(message)]),
        ]))
    }
}
