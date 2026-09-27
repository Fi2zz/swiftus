import SwiftusCore

/// 一次工具调用的请求（规格 S5 §1）。
public struct ToolCall: Sendable, Equatable {
    /// 调用标识；缺省为空，用于回喂与关联。
    public var callId = ""

    /// 工具名（注册表键）。
    public var name: String

    /// 解析后的参数对象。
    public var arguments: [String: JSONValue]

    public init(name: String, callId: String = "", arguments: [String: JSONValue] = [:]) {
        self.name = name
        self.callId = callId
        self.arguments = arguments
    }
}

/// 工具失败的结构化信息；code 为开放字符串（工具可产出自定义失败码，
/// 注册表自身的失败码全集见 Codes，规格 S5 §6）。
public struct ToolError: Sendable, Equatable {
    /// 注册表自身的失败码全集。
    public enum Codes {
        public static let invalidArgs = "INVALID_ARGS"
        public static let toolTimeout = "TOOL_TIMEOUT"
        public static let unknownTool = "UNKNOWN_TOOL"
        public static let toolDenied = "TOOL_DENIED"
        public static let toolError = "TOOL_ERROR"
    }

    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

extension ToolError: CustomStringConvertible {
    public var description: String {
        "\(code): \(message)"
    }
}

/// 一次工具调用的结局：成功携带规范值 value，失败携带 error。
public struct ToolResult: Sendable, Equatable {
    /// 是否失败。
    public let failed: Bool

    /// 模型可见的文本内容。
    public let content: String

    /// 执行体返回的规范值；失败时为 nil。
    public let value: JSONValue?

    /// 失败详情；成功时为 nil。
    public let error: ToolError?

    public static func success(_ content: String, value: JSONValue? = nil) -> ToolResult {
        ToolResult(failed: false, content: content, value: value, error: nil)
    }

    public static func failure(_ content: String, error: ToolError? = nil) -> ToolResult {
        ToolResult(failed: true, content: content, value: nil, error: error)
    }
}

/// 工具风险等级：low 只读、medium 有副作用但可回退、high 破坏性或需确认。
public enum ToolRisk: Int, Sendable, Comparable {
    case low, medium, high

    public static func < (lhs: ToolRisk, rhs: ToolRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 展示名（与 Dart enum.name 对齐）。
    public var label: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }
}

/// 单调守卫：返回非空理由即拒绝该次调用，返回 nil 放行。
public typealias ToolGuard = @ContextTreeActor (ToolCall) -> String?

/// 环绕执行的中间件：next() 交给后续管线（含工具执行体）。
public typealias ToolMiddleware = @ContextTreeActor (
    ToolCall,
    @ContextTreeActor () async throws -> ToolResult
) async throws -> ToolResult

/// 结果观察者。
public typealias ToolResultListener = @ContextTreeActor (ToolCall, ToolResult) -> Void

/// 注册表错误。
public enum ToolRegistryError: Error, Equatable {
    /// 同名工具重复注册：`工具 "name" 已注册`。
    case duplicate(String)
}
