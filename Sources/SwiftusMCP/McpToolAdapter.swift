import Foundation
import SwiftusCore
import SwiftusFoundation

/// 把一台 server 的工具适配成本地 `Tool`（规格 S11 §7）。
///
/// 入参 schema 由服务端下发，`ParamSpec` 表达不了任意 JSON Schema，因此
/// `params` 留空（空声明不做校验，多余参数不会被拒）而 `schema` 直接透传
/// 服务端 `inputSchema`。
///
/// 风险等级见 `mcpToolRisk`：**未声明的工具一律 medium**，也就是默认走审批门控
/// ——宁可多问一次，也不要让未知的写操作静默执行。
@ContextTreeActor
public final class McpToolAdapter: Tool {
    /// 工具所属的客户端（调用与命名都走它）。
    public let client: McpClient
    /// 服务端的工具声明。
    public let tool: McpTool

    public init(client: McpClient, tool: McpTool) {
        self.client = client
        self.tool = tool
    }

    public var name: String { mcpToolName(client.serverName, tool.name) }

    public var description: String { tool.description ?? tool.title ?? tool.name }

    public var riskLevel: ToolRisk { mcpToolRisk(tool) }

    public var group: String? { "mcp:\(client.serverName)" }

    /// 入参 schema 由服务端下发、原样透传给模型；本地 `ParamSpec` 表达不了任意
    /// JSON Schema，故参数声明留空（空声明不做校验，多余参数不会被拒）。
    public var params: [ParamSpec] { [] }

    /// 白名单投影的覆写：`parameters` 透传服务端 `inputSchema`，
    /// 服务端没给时给一个空对象 schema。
    public var schema: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "parameters": .object(
                tool.inputSchema.isEmpty
                    ? ["type": .string("object"), "properties": .object([:])]
                    : tool.inputSchema
            ),
        ])
    }

    public func call(_ context: ToolContext) async throws -> ToolResult {
        do {
            let result = try await client.callTool(tool.name, context.arguments)
            return toolResultFromMcp(result)
        } catch let error as McpException {
            return .failure(error.message, error: ToolError("MCP_ERROR", error.message))
        }
    }
}

/// 给已注册的 MCP 工具加一个短别名（规格 S11 §7）。
///
/// 全名 `server__tool` 对模型偏长；别名工具除名字外与被代理的工具完全一致，
/// `schema` 里的 `name` 也换成别名。写操作应继续用全名，让调用日志里保留
/// server 归属。
@ContextTreeActor
public final class McpToolAlias: Tool {
    /// 被代理的工具。
    public let inner: any Tool
    /// 短名（注册表键）。
    public let alias: String

    public init(inner: any Tool, alias: String) {
        self.inner = inner
        self.alias = alias
    }

    public var name: String { alias }

    public var description: String { inner.description }

    public var riskLevel: ToolRisk { inner.riskLevel }

    public var group: String? { inner.group }

    public var timeout: TimeInterval? { inner.timeout }

    public var pathParams: [String] { inner.pathParams }

    public var params: [ParamSpec] { inner.params }

    public var schema: JSONValue {
        var out = inner.schema.objectValue ?? [:]
        out["name"] = .string(alias)
        return .object(out)
    }

    public func call(_ context: ToolContext) async throws -> ToolResult {
        try await inner.call(context)
    }
}
