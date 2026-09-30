import Foundation
import SwiftusCore
import SwiftusFoundation

/// 一块内容：`text` / `image` / `audio` / `resource` 之一（规格 S11 §7）。
public struct McpContent: Sendable, Equatable {
    /// 内容类型。
    public let type: String
    /// 文本正文（`type == "text"`）。
    public let text: String?
    /// 二进制或资源负载（base64 字符串或资源对象）。
    public let data: JSONValue?
    /// MIME 类型；非文本内容一般都有。
    public let mimeType: String?

    public init(type: String, text: String? = nil, data: JSONValue? = nil, mimeType: String? = nil) {
        self.type = type
        self.text = text
        self.data = data
        self.mimeType = mimeType
    }

    /// 从 JSON 解析；`type` 缺失时退回 `text`。
    public init(json: [String: JSONValue]) {
        type = McpDecode.string(json["type"]) ?? "text"
        text = McpDecode.string(json["text"])
        data = json["data"]
        mimeType = McpDecode.string(json["mimeType"])
    }

    /// 序列化为 JSON（缺省字段省略）。
    public var json: [String: JSONValue] {
        var out: [String: JSONValue] = ["type": .string(type)]
        if let text { out["text"] = .string(text) }
        if let data { out["data"] = data }
        if let mimeType { out["mimeType"] = .string(mimeType) }
        return out
    }
}

/// 把内容块拼成人可读文本：文本原样衔接（换行分隔），非文本给出占位说明。
///
/// 占位说明优先用 `mimeType`（图片通常是 `[image/png]`），没有 MIME 时退回
/// 类型名（如 `[resource]`）；空文本块被跳过。
public func describeMcpContent(_ content: [McpContent]) -> String {
    content
        .map { block in
            guard block.type == "text" else {
                return "[\(block.mimeType ?? block.type)]"
            }
            return block.text ?? ""
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

/// `tools/call` 的结果（规格 S11 §7）。
public struct McpToolResult: Sendable, Equatable {
    /// 内容块列表。
    public let content: [McpContent]
    /// 线协议的 `isError` 映射到本地字段。
    public let failed: Bool
    /// 结构化结果（仅在服务端支持时给出）。
    public let structuredContent: [String: JSONValue]?

    public init(content: [McpContent] = [], failed: Bool = false, structuredContent: [String: JSONValue]? = nil) {
        self.content = content
        self.failed = failed
        self.structuredContent = structuredContent
    }

    /// 从 JSON 解析，把线协议的 `isError` 映射到本地字段。
    public init(json: [String: JSONValue]) {
        content = (McpDecode.list(json["content"]) ?? []).compactMap { item in
            McpDecode.object(item).map(McpContent.init(json:))
        }
        failed = json["isError"] == .bool(true)
        structuredContent = McpDecode.object(json["structuredContent"])
    }
}

/// 把一次 MCP 工具结果转成 `ToolResult`（规格 S11 §7）。
///
/// 线协议的 `isError` 映射到失败：失败时文本作为内容与 `ToolError.message`；
/// 成功时内容文本 + 结构化结果。
public func toolResultFromMcp(_ result: McpToolResult) -> ToolResult {
    let text = describeMcpContent(result.content)
    if result.failed {
        return .failure(text, error: ToolError("MCP_TOOL_ERROR", text))
    }
    return .success(text, value: result.structuredContent.map { JSONValue.object($0) })
}

/// 一台 server 暴露的工具（规格 S11 §7）。
public struct McpTool: Sendable, Equatable {
    /// 工具名（在 server 内唯一）。
    public let name: String
    /// 展示名（可选）。
    public let title: String?
    /// 面向模型的简介。
    public let description: String?
    /// 入参的 JSON Schema；由服务端下发，客户端原样透传给模型。
    public let inputSchema: [String: JSONValue]
    /// MCP 标准的注解（`readOnlyHint` / `destructiveHint` / `idempotentHint` / `openWorldHint`）。
    public let annotations: [String: JSONValue]
    /// **非标准扩展字段**：服务端自行声明的风险等级标签（大小写不敏感）。
    public let riskLevel: String?

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: [String: JSONValue] = [:],
        annotations: [String: JSONValue] = [:],
        riskLevel: String? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.riskLevel = riskLevel
    }

    /// 从 JSON 解析；宽松处理，缺失字段退回缺省值。
    ///
    /// `name` 缺失时为空串（服务端异常形态），上层适配器仍能注册，只是名不好看。
    public init(json: [String: JSONValue]) {
        name = McpDecode.string(json["name"]) ?? ""
        title = McpDecode.string(json["title"])
        description = McpDecode.string(json["description"])
        inputSchema = McpDecode.object(json["inputSchema"]) ?? [:]
        annotations = McpDecode.object(json["annotations"]) ?? [:]
        riskLevel = McpDecode.string(json["riskLevel"])
    }
}

/// 服务端工具在本地注册表里的名字：`server__tool`（双下划线，避开本地工具）。
public func mcpToolName(_ serverName: String, _ toolName: String) -> String {
    "\(serverName)__\(toolName)"
}

/// 把 MCP 风险信号映射成本地 `ToolRisk`（规格 S11 §7）。
///
/// 判定顺序：
/// 1. 非标准扩展字段 `riskLevel`：`readonly` / `read` → low，
///    `write` / `mutating` → medium，`destructive` / `admin` → high（大小写不敏感）；
/// 2. 标准注解 `annotations.destructiveHint == true` → high；
/// 3. `annotations.readOnlyHint == true` → low；
/// 4. 其余（含什么都没声明）→ medium，即**默认需要审批**。
public func mcpToolRisk(_ tool: McpTool) -> ToolRisk {
    if let declared = riskByTag(tool.riskLevel) { return declared }
    if tool.annotations["destructiveHint"] == .bool(true) { return .high }
    if tool.annotations["readOnlyHint"] == .bool(true) { return .low }
    return .medium
}

private let kMcpRiskByTag: [String: ToolRisk] = [
    "readonly": .low,
    "read": .low,
    "write": .medium,
    "mutating": .medium,
    "destructive": .high,
    "admin": .high,
]

private func riskByTag(_ tag: String?) -> ToolRisk? {
    guard let tag else { return nil }
    return kMcpRiskByTag[tag.lowercased()]
}
