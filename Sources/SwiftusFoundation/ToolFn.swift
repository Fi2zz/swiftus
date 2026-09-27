import SwiftusCore

/// `tools.fn(...)`：一行注册简单工具（规格 S5 §9）。
extension ToolRegistry {
    /// 注册一个由 handler 驱动的工具，返回撤销函数（幂等）。
    @discardableResult
    public func fn(
        _ name: String,
        description: String = "",
        params: [ParamSpec] = [],
        handler: @escaping @ContextTreeActor (ToolContext) async throws -> ToolResult
    ) throws -> Disposer {
        try register(FnTool(
            name: name,
            toolDescription: description,
            params: params,
            options: FnToolOptions(),
            handler: handler
        ))
    }

    /// 全形态 fn：风险、分组与路径参数经 options 声明。
    @discardableResult
    public func fn(
        _ name: String,
        options: FnToolOptions,
        handler: @escaping @ContextTreeActor (ToolContext) async throws -> ToolResult
    ) throws -> Disposer {
        try register(FnTool(
            name: name,
            toolDescription: options.description,
            params: options.params,
            options: options,
            handler: handler
        ))
    }
}

/// fn 的可选声明项。
public struct FnToolOptions {
    public var description = ""
    public var params: [ParamSpec] = []
    public var riskLevel: ToolRisk = .low
    public var group: String?
    public var pathParams: [String] = []

    public init() {}
}

/// fn 背后的工具实现。
private final class FnTool: Tool {
    let name: String
    let toolDescription: String
    let params: [ParamSpec]
    let riskLevel: ToolRisk
    let group: String?
    let pathParams: [String]
    let handler: @ContextTreeActor (ToolContext) async throws -> ToolResult

    init(
        name: String,
        toolDescription: String,
        params: [ParamSpec],
        options: FnToolOptions,
        handler: @escaping @ContextTreeActor (ToolContext) async throws -> ToolResult
    ) {
        self.name = name
        self.toolDescription = toolDescription
        self.params = params
        riskLevel = options.riskLevel
        group = options.group
        pathParams = options.pathParams
        self.handler = handler
    }

    var description: String {
        toolDescription
    }

    func call(_ context: ToolContext) async throws -> ToolResult {
        try await handler(context)
    }
}
