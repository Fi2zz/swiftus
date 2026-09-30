import Foundation
import SwiftusCore

/// 本客户端在 `initialize` 中声明的 MCP 协议版本（规格 S11 §1）。
///
/// 服务端可能回一个不同版本：客户端只记录不拒绝（见 `McpServerInfo`）。
public let kMcpProtocolVersion = "2025-06-18"

/// MCP 客户端异常：稳定的机器可读码 + 人可读消息（规格 S11 §1）。
public struct McpException: Error, Equatable, Sendable {
    /// 错误码全集（规格 S11 §1 列举，本仓只在必要处穷举）。
    public enum Codes {
        public static let timeout = "timeout"
        public static let disconnected = "disconnected"
        public static let closed = "closed"
        public static let protocolError = "protocol-error"
        public static let malformedResult = "malformed-result"
        public static let tooManyPages = "too-many-pages"
        public static let httpStatus = "http-status"
        public static let serverExited = "server-exited"
        public static let notConnected = "not-connected"
        public static let sseError = "sse-error"
        public static let sseClosed = "sse-closed"
        /// iOS 上没有子进程能力（规格 S11 §9 的有意偏离）。
        public static let unsupportedTransport = "unsupported-transport"
    }

    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

extension McpException: CustomStringConvertible {
    public var description: String {
        "McpException(\(code)): \(message)"
    }
}

// MARK: - 解析助手

/// 线协议字段的收窄助手：**收窄失败即退回缺省**，不抛错、不中断整条消息
/// （规格 S11 §3）。服务端形态各异，协议层不该因单个字段形态不对就崩掉。
public enum McpDecode {
    /// 解析 JSON 文本；失败返回 nil。
    public static func text(_ payload: String) -> JSONValue? {
        try? JSONValue.parse(Data(payload.utf8))
    }

    /// 收窄为 object；非 object 返回 nil。
    public static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        value?.objectValue
    }

    /// 收窄为字符串；非字符串返回 nil。
    public static func string(_ value: JSONValue?) -> String? {
        value?.stringValue
    }

    /// 收窄为整数；非整数返回 nil（double 不算整数——与来源 `json['x'] is int` 一致）。
    public static func int(_ value: JSONValue?) -> Int? {
        value?.intValue
    }

    /// 收窄为列表；非列表返回 nil。
    public static func list(_ value: JSONValue?) -> [JSONValue]? {
        value?.arrayValue
    }
}

// MARK: - 错误对象

/// JSON-RPC 2.0 错误对象（规格 S11 §3）。
public struct McpErrorObject: Sendable, Equatable {
    /// 错误码：JSON-RPC 标准码或服务端自定义码。
    public let code: Int
    /// 人可读的错误说明。
    public let message: String
    /// 附加数据；随服务端而定，可能缺省。
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// 从 JSON 解析；`code` / `message` 缺失时退回零值而非抛错。
    public init(json: [String: JSONValue]) {
        code = McpDecode.int(json["code"]) ?? 0
        message = McpDecode.string(json["message"]) ?? ""
        data = json["data"]
    }

    /// 序列化为 JSON；`data` 缺省时**省略键**。
    public var json: [String: JSONValue] {
        var out: [String: JSONValue] = [
            "code": .int(Int64(code)),
            "message": .string(message),
        ]
        if let data { out["data"] = data }
        return out
    }
}

extension McpErrorObject: CustomStringConvertible {
    public var description: String {
        "McpError(\(code)): \(message)"
    }
}

// MARK: - 消息信封

/// 一条 JSON-RPC 消息：请求 / 通知 / 响应三态合一（规格 S11 §3）。
///
/// 三态由字段组合判定：`method` 与 `id` 俱全的是请求；只有 `method` 的是通知
/// （单向，不期待回复）；没有 `method` 的是响应。
public struct McpMessage: Sendable, Equatable {
    /// 消息 id；请求与响应有，通知没有。
    public let id: JSONValue?
    /// 方法名；响应没有。
    public let method: String?
    /// 调用参数；无参时缺省。
    public let params: [String: JSONValue]?
    /// 成功结果；非响应或失败时缺省。
    public let result: JSONValue?
    /// 失败信息；非失败响应时缺省。
    public let error: McpErrorObject?

    public init(
        id: JSONValue? = nil,
        method: String? = nil,
        params: [String: JSONValue]? = nil,
        result: JSONValue? = nil,
        error: McpErrorObject? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    /// 构造请求。
    public static func request(id: JSONValue, method: String, params: [String: JSONValue]? = nil) -> McpMessage {
        McpMessage(id: id, method: method, params: params)
    }

    /// 构造通知。
    public static func notification(method: String, params: [String: JSONValue]? = nil) -> McpMessage {
        McpMessage(method: method, params: params)
    }

    /// 从 JSON 解析；字段形态不合法时该字段缺省，不抛错。
    public init(json: [String: JSONValue]) {
        id = json["id"]
        method = McpDecode.string(json["method"])
        params = McpDecode.object(json["params"])
        result = json["result"]
        error = McpDecode.object(json["error"]).map(McpErrorObject.init(json:))
    }

    /// 是否需要服务端回一条响应。
    public var isRequest: Bool { method != nil && id != nil }

    /// 是否是单向通知。
    public var isNotification: Bool { method != nil && id == nil }

    /// 是否是响应。
    public var isResponse: Bool { method == nil }

    /// 序列化为 JSON；`jsonrpc` 固定为 `2.0`。
    public var json: [String: JSONValue] {
        var out: [String: JSONValue] = ["jsonrpc": .string("2.0")]
        if let method { out["method"] = .string(method) }
        if let params { out["params"] = .object(params) }
        if let id { out["id"] = id }
        if let error { out["error"] = .object(error.json) }
        if isResponse, error == nil { out["result"] = result ?? .null }
        return out
    }

    /// 客户端自增 id 的请求（id 是协议的一部分，用整数）。
    public static func request(id: Int, method: String, params: [String: JSONValue]? = nil) -> McpMessage {
        request(id: .int(Int64(id)), method: method, params: params)
    }
}

extension McpMessage: CustomStringConvertible {
    public var description: String {
        let head = method ?? "id=\(id.map { $0.jsonDataText } ?? "nil")"
        return error == nil ? "McpMessage(\(head))" : "McpMessage(\(head) \(error!))"
    }
}

// MARK: - 握手结果

/// `initialize` 的握手结果（规格 S11 §3）。
///
/// 标准的形态是 `{protocolVersion, capabilities, serverInfo: {name, version}}`；
/// 也接受把 `name` / `version` 直接放在顶层的宽容形态。服务端返回的协议版本
/// 照收不误（只记录，不拒绝）。
public struct McpServerInfo: Sendable, Equatable {
    /// 服务端声明的协议版本。
    public let protocolVersion: String
    /// 服务端名。
    public let name: String?
    /// 服务端版本。
    public let version: String?
    /// 给模型的用法说明（可选）。
    public let instructions: String?
    /// 能力声明（`tools` / `resources` / `prompts` …）。
    public let capabilities: [String: JSONValue]

    public init(
        protocolVersion: String,
        name: String? = nil,
        version: String? = nil,
        instructions: String? = nil,
        capabilities: [String: JSONValue] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.name = name
        self.version = version
        self.instructions = instructions
        self.capabilities = capabilities
    }

    /// 从 `initialize` 响应的 `result` 解析。
    public init(json: [String: JSONValue]) {
        let info = McpDecode.object(json["serverInfo"]) ?? json
        protocolVersion = McpDecode.string(json["protocolVersion"]) ?? kMcpProtocolVersion
        name = McpDecode.string(info["name"])
        version = McpDecode.string(info["version"])
        instructions = McpDecode.string(json["instructions"])
        capabilities = McpDecode.object(json["capabilities"]) ?? [:]
    }
}

extension JSONValue {
    /// 展示用短文本（异常与日志里用；不是规格面）。
    var jsonDataText: String {
        (try? jsonData()).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }
}
