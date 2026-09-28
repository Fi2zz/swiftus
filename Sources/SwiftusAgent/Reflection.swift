import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 反思触发策略（规格 S16 §2.1）。
public enum ReflectionStrategy: String, Sendable, CaseIterable {
    /// 每次工具调用后都反思。
    case always
    /// 只在工具失败时反思（默认）。
    case onError
    /// 只在非只读（riskLevel != low）工具后反思。
    case onRisk
    /// 关闭反思。
    case never
}

/// 把字符串解析为策略（大小写不敏感、去空白按名字）；无法识别时返回 nil。
public func parseReflectionStrategy(_ value: String) -> ReflectionStrategy? {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ReflectionStrategy.allCases.first { $0.rawValue.lowercased() == name }
}

/// 反思决策的动作（rawValue 对齐 Dart enum.name）。
public enum ReflectionAction: String, Sendable, Equatable {
    case continueRun
    case retry
    case replan
}

/// 一次反思的结论（规格 S16 §2.2）。
public struct ReflectionDecision: Sendable, Equatable {
    /// 动作。
    public let action: ReflectionAction
    /// 理由（模型给出，可为空）。
    public let reason: String

    public init(_ action: ReflectionAction, reason: String = "") {
        self.action = action
        self.reason = reason
    }

    /// 从模型文本解析决策：优先 JSON 的 decision，否则关键词（retry 优先于
    /// replan），兜底 continue。
    public static func parse(_ text: String) -> ReflectionDecision {
        let pattern = /"decision"\s*:\s*"?(continue|retry|replan)"?/.ignoresCase()
        let token: String
        if let match = text.firstMatch(of: pattern) {
            token = String(match.output.1).lowercased()
        } else {
            token = text.lowercased()
        }
        if token.contains("retry") {
            return ReflectionDecision(.retry)
        }
        if token.contains("replan") {
            return ReflectionDecision(.replan)
        }
        return ReflectionDecision(.continueRun)
    }
}

/// 反思器：独立 LLM 调用 + 可配置策略（规格 S16 §2.3）。
@ContextTreeActor
public final class Reflector {
    /// 用于反思的模型（可与主 Agent 不同）。
    public let llm: any LlmProvider
    /// 触发策略。
    public let strategy: ReflectionStrategy
    /// 反思调用传给模型的 options（如更省的最大 token）。
    public let options: [String: JSONValue]?
    /// 每条工具调用的最大重试次数。
    public let maxRetries: Int

    public init(
        llm: any LlmProvider,
        strategy: ReflectionStrategy = .onError,
        options: [String: JSONValue]? = nil,
        maxRetries: Int = 1
    ) {
        self.llm = llm
        self.strategy = strategy
        self.options = options
        self.maxRetries = maxRetries
    }

    /// 是否应对该工具结果发起反思。
    public func shouldReflect(_ tool: any Tool, _ result: ToolResult) -> Bool {
        if strategy == .never { return false }
        if strategy == .always { return true }
        if strategy == .onRisk { return tool.riskLevel != .low }
        return result.failed
    }

    /// 发起一次反思调用，返回决策（prompt 模板为协议文本，规格 S16 §2.3）。
    public func reflect(
        task: String,
        call: LlmToolCall,
        result: ToolResult,
        plan: Plan?
    ) async throws -> ReflectionDecision {
        let prompt = "你是一个任务执行监督者。当前任务：\(task)\n"
            + "当前计划：\n\(plan?.summary() ?? "（无）")\n"
            + "刚执行的工具：\(call.name)\n"
            + "工具返回结果：\(clip(result.content))\n"
            + "结果状态：\(result.failed ? "失败" : "成功")\n\n"
            + "请评估并按 JSON 回答："
            + "{\"decision\":\"continue|retry|replan\",\"reason\":\"简短理由\"}\n"
            + "- continue：结果符合预期，继续；\n"
            + "- retry：结果不符合预期，应重试该工具；\n"
            + "- replan：需要调整计划，重新规划。"
        var request = LlmRequest(messages: [LlmMessage("user", prompt)])
        request.options = options
        let response = try await llm.chat(request)
        return ReflectionDecision.parse(response.content)
    }

    /// 截断到 800 字符（超出补省略号）。
    private func clip(_ text: String) -> String {
        text.count <= 800 ? text : String(text.prefix(800)) + "…"
    }
}

/// 反思回填路径的输入（参数封装）。
public struct ReflectionContext {
    /// 工具注册表。
    public var tools: ToolRegistry
    /// 当前任务（用户输入）。
    public var task: String
    /// 当前计划（可无）。
    public var plan: Plan?
    /// 重跑该工具调用的执行体。
    public var invoke: @ContextTreeActor (LlmToolCall) async throws -> ToolResult
    /// replan 决策的回调（置位重新规划）。
    public var onReplan: (@ContextTreeActor () -> Void)?

    public init(
        tools: ToolRegistry,
        task: String,
        plan: Plan?,
        invoke: @escaping @ContextTreeActor (LlmToolCall) async throws -> ToolResult,
        onReplan: (@ContextTreeActor () -> Void)? = nil
    ) {
        self.tools = tools
        self.task = task
        self.plan = plan
        self.invoke = invoke
        self.onReplan = onReplan
    }
}

/// 在工具回填路径上应用反思（规格 S16 §2.3）：必要时重试该工具（有界），
/// 或标记需要重新规划。返回最终采用的结果；工具未注册直接返回初值。
@ContextTreeActor
public func reflectAndRetry(
    _ reflector: Reflector,
    call: LlmToolCall,
    initial: ToolResult,
    context: ReflectionContext
) async throws -> ToolResult {
    var outcome = initial
    guard let tool = context.tools.get(call.name) else { return outcome }
    var retries = 0
    while reflector.shouldReflect(tool, outcome), retries < reflector.maxRetries {
        let decision = try await reflector.reflect(
            task: context.task,
            call: call,
            result: outcome,
            plan: context.plan
        )
        if decision.action == .retry {
            retries += 1
            outcome = try await context.invoke(call)
            continue
        }
        if decision.action == .replan {
            context.onReplan?()
        }
        break
    }
    return outcome
}

/// 'reflection' 服务键。
extension ServiceKey where Service == Reflector {
    public static let reflection = ServiceKey<Reflector>("reflection")
}

/// 'reflectionStrategy' 配置键（字符串形态，经 parseReflectionStrategy 解析）。
extension ServiceKey where Service == String {
    public static let reflectionStrategy = ServiceKey<String>("reflectionStrategy")
}

/// 反思装配的输入（参数封装）。
public struct ReflectionConfig {
    /// 显式实例（优先）。
    public var reflector: Reflector?
    /// 反思模型（缺省取上下文 'llm'）。
    public var llm: (any LlmProvider)?
    /// 触发策略（缺省取上下文 'reflectionStrategy'，再缺省 onError）。
    public var strategy: ReflectionStrategy?
    /// 反思调用的模型 options。
    public var options: [String: JSONValue]?
    /// 每条工具调用的最大重试次数。
    public var maxRetries = 1

    public init() {}
}

/// 把 Reflector 作为 'reflection' 服务提供到上下文（规格 S16 §2.3）。
@ContextTreeActor
@discardableResult
public func provideReflection(_ ctx: Context, config: ReflectionConfig = ReflectionConfig()) throws -> Reflector {
    let strategy = config.strategy
        ?? ctx.get(.reflectionStrategy).flatMap(parseReflectionStrategy)
        ?? .onError
    let resolved = try config.reflector ?? Reflector(
        llm: config.llm ?? ctx.require(.llm),
        strategy: strategy,
        options: config.options,
        maxRetries: config.maxRetries
    )
    try ctx.provide(.reflection, resolved)
    return resolved
}
