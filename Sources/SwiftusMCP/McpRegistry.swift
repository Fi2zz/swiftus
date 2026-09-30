import Foundation
import SwiftusCore
import SwiftusCredentials
import SwiftusFoundation

/// 已装配的 MCP server 集合，服务键 `mcp`（见 `ctx.mcp`，规格 S11 §8）。
///
/// 一台 server 的运行时绑定 = 客户端 + 已注册适配器 + 撤销句柄。断连（服务端
/// 崩溃、连接被掐）时只注销该 server 的工具，其余 server 照常可用——MCP 服务端
/// 是外部进程，随时可能消失，不能让它拖垮整张工具表。
@ContextTreeActor
public final class McpRegistry {
    private var bindings: [String: McpBinding] = [:]
    private var order: [String] = []

    public init() {}

    /// 已装配且连接仍活着的 server 名（按装配顺序）。
    public var servers: [String] { order }

    /// 某 server 的客户端；未装配（或已断连注销）返回 nil。
    public func client(of serverName: String) -> McpClient? {
        bindings[serverName]?.client
    }

    /// 某 server 当前注册的适配器（不含别名工具）。
    public func tools(of serverName: String) -> [McpToolAdapter] {
        bindings[serverName]?.tools ?? []
    }

    /// 装配一台 server：握手、发现工具、注册进 `ctx.tools`，并订阅其断连。
    ///
    /// 握手或发现失败时先断开该客户端再抛出（不留悬空子进程），且不上账，
    /// 因此 `servers` 里不会留下半死条目。同名 server 重复装配失败。
    public func attach(_ context: Context, _ client: McpClient) async throws {
        let name = client.serverName
        guard bindings[name] == nil else {
            throw McpRegistryError.duplicate(name)
        }
        do {
            _ = try await client.initialize()
            let tools = try await client.listTools()
            let binding = McpBinding(client: client)
            bindings[name] = binding
            order.append(name)
            for tool in tools {
                try binding.add(context, McpToolAdapter(client: client, tool: tool))
            }
            binding.watchDisconnect { [weak self] in
                self?.drop(name)
            }
        } catch {
            bindings.removeValue(forKey: name)
            order.removeAll { $0 == name }
            await client.close()
            throw error
        }
    }

    /// 给已注册的全名工具登记一个短别名（如 `read_file` → `fs__read_file`）。
    ///
    /// 目标工具不存在抛 `McpRegistryError.unknownAliasTarget`；短名与已有工具撞车
    /// 由 `ToolRegistry.register` 抛 `ToolRegistryError.duplicate`。
    public func addAlias(_ context: Context, _ alias: String, _ fullName: String) throws {
        guard let binding = bindings.first(where: { $0.value.holds(fullName) })?.value,
              let inner = binding.require(fullName) else {
            throw McpRegistryError.unknownAliasTarget(alias: alias, fullName: fullName)
        }
        try binding.add(context, McpToolAlias(inner: inner, alias: alias))
    }

    /// 断开全部连接并注销全部工具；幂等。
    public func close() async {
        let all = order.compactMap { bindings[$0] }
        bindings.removeAll()
        order.removeAll()
        for binding in all {
            await binding.close()
        }
    }

    private func drop(_ serverName: String) {
        bindings.removeValue(forKey: serverName)
        order.removeAll { $0 == serverName }
    }
}

/// 注册表语义错误（对应来源侧的 `StateError`，规格 S11 §8）。
public enum McpRegistryError: Error, Equatable, Sendable {
    case duplicate(String)
    case unknownAliasTarget(alias: String, fullName: String)
}

extension McpRegistryError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .duplicate(name):
            return "MCP server \"\(name)\" 已装配"
        case let .unknownAliasTarget(alias, fullName):
            return "别名 \"\(alias)\" 的目标工具 \"\(fullName)\" 未注册"
        }
    }
}

/// 一台 server 的运行时绑定：客户端、已注册工具与撤销句柄。
@ContextTreeActor
final class McpBinding {
    let client: McpClient
    private(set) var tools: [McpToolAdapter] = []
    private var disposers: [Disposer] = []

    init(client: McpClient) {
        self.client = client
    }

    /// 注册一个工具（含别名）并记住撤销句柄；`context` 释放时也会撤销（幂等）。
    func add(_ context: Context, _ tool: any Tool) throws {
        let off = try context.tools.register(tool)
        disposers.append(off)
        context.onDispose { try? off() }
        if let adapter = tool as? McpToolAdapter {
            tools.append(adapter)
        }
    }

    /// 该绑定是否持有全名为 `fullName` 的适配器。
    func holds(_ fullName: String) -> Bool {
        tools.contains { $0.name == fullName }
    }

    /// 按全名取适配器；不存在返回 nil。
    func require(_ fullName: String) -> McpToolAdapter? {
        tools.first { $0.name == fullName }
    }

    /// 订阅客户端断连：注销本 server 的工具后回调 `onGone`。
    func watchDisconnect(_ onGone: @escaping @ContextTreeActor () -> Void) {
        client.onDisconnect = { [weak self] _ in
            guard let self else { return }
            self.detachTools()
            onGone()
        }
    }

    /// 注销本 server 注册的全部工具。
    ///
    /// 撤销函数按契约幂等（可能被上下文释放先调过一次），因此逐个 `try?` 收掉。
    func detachTools() {
        for off in disposers {
            try? off()
        }
        disposers.removeAll()
        tools.removeAll()
    }

    /// 断开客户端并注销工具。
    func close() async {
        client.onDisconnect = nil
        detachTools()
        await client.close()
    }
}

/// 'mcp' 服务键。
extension ServiceKey where Service == McpRegistry {
    public static let mcp = ServiceKey<McpRegistry>("mcp")
}

extension Context {
    /// `ctx.mcp`：当前上下文可见的 MCP 注册表（未提供时抛错，规格 S11 §8）。
    public var mcp: McpRegistry {
        guard let registry = get(.mcp) else {
            fatalError("上下文中没有 MCP 注册表（服务键 \"mcp\" 未提供）。")
        }
        return registry
    }
}

/// MCP 装配：从配置连起全部 server，并把它们的工具接进 `ctx.tools`（规格 S11 §8）。
///
/// 随上下文释放自动断开全部连接并注销工具。
///
/// - `aliases` 是「短名 → 已注册全名」的映射，如 `{"read_file": "fs__read_file"}`；
///   目标工具不存在时抛 `McpRegistryError.unknownAliasTarget`。
/// - `credentials` 用于解析 `McpServerConfig.env` / `headers` 里的 `${KEY}` 占位符；
///   缺省时占位符原样保留（见 `resolveCredentialPlaceholders`）。
/// - `transportFactory` 用于测试与自定义传输：给出时由它按配置造传输，缺省按
///   `McpServerConfig.type` 分派到 `StdioTransport` / `HttpTransport` /
///   `SseTransport`。它收到的配置已做过凭据占位符解析。
@discardableResult
@ContextTreeActor
public func provideMcp(
    _ context: Context,
    _ servers: [McpServerConfig],
    aliases: [String: String] = [:],
    credentials: (any Credentials)? = nil,
    transportFactory: (@ContextTreeActor (McpServerConfig) -> any McpTransport)? = nil
) async throws -> McpRegistry {
    let registry = McpRegistry()
    let off = try context.provide(.mcp, registry)
    context.onDispose {
        Task { await registry.close() }
    }
    context.onDispose(off)
    for config in servers {
        try await registry.attach(context, client(for: config, credentials: credentials, transportFactory: transportFactory))
    }
    for (alias, fullName) in aliases.sorted(by: { $0.key < $1.key }) {
        try registry.addAlias(context, alias, fullName)
    }
    return registry
}

/// 按 `config` 造一个客户端（含 `${KEY}` 占位符解析与传输分派）。
@ContextTreeActor
func client(
    for config: McpServerConfig,
    credentials: (any Credentials)?,
    transportFactory: (@ContextTreeActor (McpServerConfig) -> any McpTransport)?
) -> McpClient {
    let resolved = resolve(config, credentials: credentials)
    let transport = transportFactory.map { $0(resolved) } ?? defaultMcpTransport(resolved)
    return McpClient(transport: transport, serverName: resolved.name)
}

@ContextTreeActor
private func resolve(_ config: McpServerConfig, credentials: (any Credentials)?) -> McpServerConfig {
    guard let credentials else { return config }
    // 复制并覆盖 env / headers 的占位符（copyWith 只能覆盖成非空值，这里两处都有值）。
    guard let replaced = try? config.copyWith(
        env: resolveCredentialPlaceholders(config.env, credentials),
        headers: resolveCredentialPlaceholders(config.headers, credentials)
    ) else {
        return config
    }
    return replaced
}

/// 按 `McpServerConfig.type` 分派默认传输。
@ContextTreeActor
public func defaultMcpTransport(_ config: McpServerConfig) -> any McpTransport {
    switch config.type {
    case .stdio:
        #if os(macOS)
        return StdioTransport(
            command: config.command ?? "",
            args: config.args,
            env: config.env
        )
        #else
        // iOS 没有子进程能力（规格 S11 §9 的有意偏离）：明确失败并说明原因。
        return UnsupportedMcpTransport(
            reason: "iOS 无法启动子进程；stdio 传输只在 macOS 可用（server \"\(config.name)\"）。"
        )
        #endif
    case .http:
        guard let url = config.url.flatMap({ URL(string: $0) }) else {
            return UnsupportedMcpTransport(reason: "MCP 端点地址不合法：\(config.url ?? "")")
        }
        return HttpTransport(url: url, headers: config.headers)
    case .sse:
        guard let url = config.url.flatMap({ URL(string: $0) }) else {
            return UnsupportedMcpTransport(reason: "MCP 端点地址不合法：\(config.url ?? "")")
        }
        return SseTransport(url: url, headers: config.headers)
    }
}

/// 占位传输：构造期就注定不可用，`connect` 时按 `reason` 失败。
///
/// 用于 iOS 的 stdio 分支与非法端点地址：让「装配时就失败」有一条明确的通道，
/// 而不是让调用方拿到一个 nil 传输。
@ContextTreeActor
public final class UnsupportedMcpTransport: McpTransport {
    private let sink = McpMessageSink()
    private let diagnostics = McpDiagnostics()
    /// 失败原因。
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func connect() async throws {
        throw McpException(McpException.Codes.unsupportedTransport, reason)
    }

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
        throw McpException(McpException.Codes.unsupportedTransport, reason)
    }
}
