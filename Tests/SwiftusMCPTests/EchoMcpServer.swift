#!/usr/bin/env swift
// stdio 端到端测试用的回声 MCP server（规格 S11 §5 的 stdio 传输）。
//
// 只依赖 Foundation：逐行读 stdin，每行一条 JSON-RPC 请求，按 method 回响应。
// 故意写得不健壮（不做完整 JSON 解析），它只服务这一个测试：
//   initialize    → 握手结果（serverInfo.name = "echo"）
//   tools/list    → 一个 `echo` 工具，required: ["text"]
//   tools/call    → 原样回显 arguments（文本 + structuredContent）
import Foundation

let toolName = "echo"
let serverInfo: [String: Any] = [
    "protocolVersion": "2025-06-18",
    "capabilities": ["tools": [String: Any]()],
    "serverInfo": ["name": "echo", "version": "0.0.1"],
]

func write(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          var line = String(data: data, encoding: .utf8) else { return }
    line.append("\n")
    FileHandle.standardOutput.write(Data(line.utf8))
}

while let line = readLine(strippingNewline: true), !line.isEmpty {
    guard let data = line.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        continue // 坏行忽略（与来源的 stdio 传输同款：只影响这一行）
    }
    let id = request["id"]
    let method = request["method"] as? String
    // 通知没有 id，不回响应。
    guard let id else { continue }

    var result: [String: Any]
    switch method {
    case "initialize":
        result = serverInfo
    case "tools/list":
        result = [
            "tools": [[
                "name": toolName,
                "description": "原样回显 arguments",
                "inputSchema": [
                    "type": "object",
                    "properties": ["text": ["type": "string"]],
                    "required": ["text"],
                ],
            ]]
        ]
    case "tools/call":
        let params = request["params"] as? [String: Any]
        let arguments = params?["arguments"] as? [String: Any] ?? [:]
        let echoed = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        result = [
            "content": [["type": "text", "text": echoed]],
            "structuredContent": arguments,
        ]
    default:
        write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "方法不存在"]])
        continue
    }
    write(["jsonrpc": "2.0", "id": id, "result": result])
}
