import Foundation
import SwiftusCore

/// 工具注册表与执行管线（规格 S5）。
///
/// 注册的工具面向模型暴露白名单 schema（执行体等宿主字段永不外泄）；
/// call 走「校验 → 守卫 → 中间件链 → 执行体 → 广播」管线，
/// 参数不合法、超时、未知工具、守卫拒绝与执行体异常都收敛为失败结果。
@ContextTreeActor
public final class ToolRegistry {
    /// call 未传 timeout 时使用的默认超时；nil 表示不限时。
    public var defaultTimeout: TimeInterval?

    private var tools: [String: any Tool] = [:]
    private var registrationOrder: [String] = []
    private var guards: [(token: Int, body: ToolGuard)] = []
    private var middlewares: [(token: Int, body: ToolMiddleware)] = []
    private var changeListeners: [(token: Int, body: @ContextTreeActor () -> Void)] = []
    private var resultListeners: [(token: Int, body: ToolResultListener)] = []
    private var nextToken = 0

    /// 分组登记（规格 S5 注记：直接存于实例，替代 Dart 的 Expando）。
    var assignedGroups: [String: String] = [:]

    public init(defaultTimeout: TimeInterval? = nil) {
        self.defaultTimeout = defaultTimeout
    }

    /// 已注册的工具名（按注册顺序）。
    public var names: [String] {
        registrationOrder
    }

    /// 已注册的工具数。
    public var length: Int {
        tools.count
    }

    /// 查找工具；未注册返回 nil。
    public func get(_ name: String) -> (any Tool)? {
        tools[name]
    }

    /// 注册一个工具；同名重复注册抛 ToolRegistryError.duplicate，返回幂等 Disposer。
    @discardableResult
    public func register(_ tool: any Tool) throws -> Disposer {
        guard tools[tool.name] == nil else {
            throw ToolRegistryError.duplicate(tool.name)
        }
        tools[tool.name] = tool
        registrationOrder.append(tool.name)
        notifyChange()
        var removed = false
        return { [weak self] in
            guard let self, !removed else { return }
            removed = true
            guard self.tools[tool.name] === tool else { return }
            self.tools.removeValue(forKey: tool.name)
            self.registrationOrder.removeAll { $0 == tool.name }
            self.notifyChange()
        }
    }

    /// 当前可见工具的模型 schema 列表（白名单投影，注册顺序）。
    public func describe() -> [JSONValue] {
        registrationOrder.compactMap { tools[$0]?.schema }
    }

    /// 按名描述单个工具；未注册返回 nil。
    public func describeOne(_ name: String) -> JSONValue? {
        tools[name]?.schema
    }

    /// 登记一个单调守卫，返回注销令牌。
    @discardableResult
    public func addGuard(_ body: @escaping ToolGuard) -> Int {
        appendPipelineListener(to: &guards, body: body)
    }

    /// 登记一个环绕中间件（先注册者为最外层），返回注销令牌。
    @discardableResult
    public func use(_ body: @escaping ToolMiddleware) -> Int {
        appendPipelineListener(to: &middlewares, body: body)
    }

    /// 监听工具表变更，返回注销令牌。
    @discardableResult
    public func onChange(_ body: @escaping @ContextTreeActor () -> Void) -> Int {
        appendPipelineListener(to: &changeListeners, body: body)
    }

    /// 监听每次调用结局，返回注销令牌。
    @discardableResult
    public func onResult(_ body: @escaping ToolResultListener) -> Int {
        appendPipelineListener(to: &resultListeners, body: body)
    }

    /// 注销一个管线监听（守卫 / 中间件 / 变更 / 结果），返回是否确实移除。
    @discardableResult
    public func removePipelineListener(_ token: Int) -> Bool {
        let pipeline = removeFrom(&guards, token: token) || removeFrom(&middlewares, token: token)
        return pipeline || removeFrom(&changeListeners, token: token) || removeFrom(&resultListeners, token: token)
    }

    /// 调用一个工具：校验参数 → 守卫 → 中间件链 → 执行体 → 广播结果（规格 S5 §6）。
    /// timeout 覆盖 Tool.timeout，后者又覆盖 defaultTimeout。
    @discardableResult
    public func call(_ call: ToolCall, timeout: TimeInterval? = nil) async -> ToolResult {
        let result = await dispatch(call, timeout: timeout)
        for entry in resultListeners {
            entry.body(call, result)
        }
        return result
    }

    private func dispatch(_ call: ToolCall, timeout: TimeInterval?) async -> ToolResult {
        guard let tool = tools[call.name] else {
            return .failure(
                "未知工具 \"\(call.name)\"",
                error: ToolError(.unknownTool, "unknown tool \"\(call.name)\"")
            )
        }
        let violations = validateToolArgs(tool, call.arguments)
        guard violations.isEmpty else {
            return .failure(
                "参数不合法：\(violations.joined(separator: "；"))",
                error: ToolError(.invalidArgs, violations.joined(separator: "; "))
            )
        }
        if let denial = firstDenial(call) {
            return .failure(denial, error: ToolError(.toolDenied, denial))
        }
        let effective = timeout ?? tool.timeout ?? defaultTimeout
        do {
            return try await withTimeout(effective, call: call) {
                try await self.chain(tool, call: call)()
            }
        } catch {
            return .failure("\(error)", error: ToolError(.toolError, "\(error)"))
        }
    }

    private func firstDenial(_ call: ToolCall) -> String? {
        for entry in guards {
            if let denial = entry.body(call) { return denial }
        }
        return nil
    }

    /// 中间件链：先注册者为最外层（后进先出包裹执行体）。
    private func chain(_ tool: any Tool, call: ToolCall) -> @ContextTreeActor () async throws -> ToolResult {
        var body: @ContextTreeActor () async throws -> ToolResult = {
            try await tool.call(ToolContext(call))
        }
        for entry in middlewares.reversed() {
            let next = body
            body = { try await entry.body(call, next) }
        }
        return body
    }

    /// 超时竞速：超时返回 TOOL_TIMEOUT 失败值；执行体续跑被忽略（与 Dart 一致，规格 S5 注记）。
    private func withTimeout(
        _ timeout: TimeInterval?,
        call: ToolCall,
        operation: @escaping @ContextTreeActor () async throws -> ToolResult
    ) async throws -> ToolResult {
        guard let timeout else { return try await operation() }
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let complete: @ContextTreeActor (Result<ToolResult, any Error>) -> Void = { outcome in
                guard !finished else { return }
                finished = true
                continuation.resume(with: outcome)
            }
            let race = Task {
                do {
                    complete(.success(try await operation()))
                } catch {
                    complete(.failure(error))
                }
            }
            Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return
                }
                race.cancel()
                complete(.success(ToolResult.failure(
                    "工具 \"\(call.name)\" 超时（\(Int(timeout * 1000))ms）",
                    error: ToolError(.toolTimeout, "\(call.name) timed out")
                )))
            }
        }
    }

    private func appendPipelineListener<T>(to list: inout [(token: Int, body: T)], body: T) -> Int {
        nextToken += 1
        list.append((token: nextToken, body: body))
        return nextToken
    }

    private func removeFrom<T>(_ list: inout [(token: Int, body: T)], token: Int) -> Bool {
        guard let index = list.firstIndex(where: { $0.token == token }) else { return false }
        list.remove(at: index)
        return true
    }

    private func notifyChange() {
        for entry in changeListeners {
            entry.body()
        }
    }
}

/// `ctx.tools`：当前上下文可见的工具注册表（未提供时抛错）。
extension Context {
    public var tools: ToolRegistry {
        get throws { try require(.tools) }
    }
}

/// 'tools' 服务键。
extension ServiceKey where Service == ToolRegistry {
    public static let tools = ServiceKey<ToolRegistry>("tools")
}

/// 将 ToolRegistry 作为 'tools' 服务提供到上下文（规格 S5 §10）。
@ContextTreeActor
@discardableResult
public func provideTools(_ ctx: Context, registry: ToolRegistry? = nil, timeout: TimeInterval? = nil) throws -> ToolRegistry {
    let resolved = registry ?? ToolRegistry(defaultTimeout: timeout)
    try ctx.provide(.tools, resolved)
    return resolved
}
