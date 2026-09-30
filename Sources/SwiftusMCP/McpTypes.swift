import Foundation
import SwiftusCore
import SwiftusCredentials

/// 传输类型（规格 S11 §1）。
public enum McpTransportType: String, Sendable, CaseIterable {
    case stdio, http, sse
}

/// 一台 MCP server 的连接配置（规格 S11 §2）。
///
/// 构造期即校验：名称非空；`stdio` 必须有 `command`，`http` / `sse` 必须有
/// `url`，不合规抛 `McpConfigError`——装配时就失败胜过连接时才失败。
///
/// `env` 与 `headers` 的值可以写 `${KEY}` 凭据占位符，由
/// `resolveCredentialPlaceholders` 在装配时解析。
public struct McpServerConfig: Sendable, Equatable {
    /// server 名：既做工具名前缀（`server__tool`），也做 `McpRegistry` 的键。
    public let name: String
    /// 传输类型。
    public let type: McpTransportType
    /// `stdio` 传输的可执行文件。
    public let command: String?
    /// `stdio` 传输的命令行参数。
    public let args: [String]
    /// `stdio` 传输注入子进程的环境变量。
    public let env: [String: String]
    /// `http` / `sse` 传输的端点地址。
    public let url: String?
    /// `http` / `sse` 传输的附加请求头（如 `Authorization`）。
    public let headers: [String: String]

    /// 构造并校验。
    public init(
        name: String,
        type: McpTransportType,
        command: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        url: String? = nil,
        headers: [String: String] = [:]
    ) throws {
        guard !name.isEmpty else {
            throw McpConfigError.invalid(name: "name", message: "MCP server 名不能为空")
        }
        switch type {
        case .stdio:
            guard let command, !command.isEmpty else {
                throw McpConfigError.invalid(name: "command", message: "stdio 传输需要 command")
            }
        case .http, .sse:
            guard let url, !url.isEmpty else {
                throw McpConfigError.invalid(name: "url", message: "\(type.rawValue) 传输需要 url")
            }
        }
        self.name = name
        self.type = type
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
    }

    /// 复制并覆盖部分字段。
    ///
    /// 只能覆盖成非空值；不能把 `command` / `url` 改回空缺。
    public func copyWith(
        name: String? = nil,
        type: McpTransportType? = nil,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        url: String? = nil,
        headers: [String: String]? = nil
    ) throws -> McpServerConfig {
        try McpServerConfig(
            name: name ?? self.name,
            type: type ?? self.type,
            command: command ?? self.command,
            args: args ?? self.args,
            env: env ?? self.env,
            url: url ?? self.url,
            headers: headers ?? self.headers
        )
    }
}

/// 配置校验失败（对应来源侧的 `ArgumentError`，规格 S11 §2）。
public struct McpConfigError: Error, Equatable, Sendable {
    /// 出问题的字段名（`name` / `command` / `url`）。
    public let name: String
    public let message: String

    public static func invalid(name: String, message: String) -> McpConfigError {
        McpConfigError(name: name, message: message)
    }
}

extension McpConfigError: CustomStringConvertible {
    public var description: String {
        "Invalid argument(s) (\(name)): \(message)"
    }
}

/// 把值里的 `${KEY}` 占位符替换成凭据服务里的同名凭据（规格 S11 §8）。
///
/// 解析不了（`credentials` 为 nil、键不存在或取凭据时抛错）的占位符**原样
/// 保留**：不抛错、不写日志、不打印明文。
///
/// **返回值可能含明文凭据**：调用方不得把它写进日志、事件、会话记录或任何模型
/// 可见的字段。
@ContextTreeActor
public func resolveCredentialPlaceholders(
    _ raw: [String: String],
    _ credentials: (any Credentials)?
) -> [String: String] {
    guard let credentials else { return raw }
    var out: [String: String] = [:]
    out.reserveCapacity(raw.count)
    for (key, value) in raw {
        out[key] = resolvePlaceholders(value, credentials)
    }
    return out
}

@ContextTreeActor
private func resolvePlaceholders(_ value: String, _ credentials: any Credentials) -> String {
    // 形态：函数内正则字面量（`Regex` 不是 Sendable，不能做全局常量；本仓统一形态）。
    value.replacing(/\$\{([A-Za-z0-9_]+)\}/) { match in
        // 键不存在（`get` 返回 nil）时原样保留：装配不该因一个坏键炸掉。
        credentials.get(String(match.output.1))?.value ?? String(match.output.0)
    }
}
