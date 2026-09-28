import SwiftusCore
import SwiftusFoundation

/// goal 装配的输入（参数封装）。
public struct GoalConfig {
    /// 显式服务实例（优先）。
    public var goal: (any GoalService)?
    /// 目标持久化到的会话。
    public var session: Session?
    /// system prompt 注册表（注入 goal 段）。
    public var prompt: SystemPrompt?
    /// 工具注册表（缺省取上下文）。
    public var tools: ToolRegistry?
    /// clear / complete 的审批端口。
    public var approval: (any Approval)?
    /// 遥测埋点。
    public var telemetry: (any Telemetry)?
    /// 新建目标缺省的轮次上限。
    public var defaultMaxRounds = 256

    public init() {}
}

/// 提供 'goal' 服务并注册目标管理工具（规格 S16 §7.5）。
///
/// 依赖（全部可选，缺省时降级）：session 持久化 goal/changed 事件、systemPrompt
/// 注入 goal 段、approval clear / complete 确认（缺省自动批准）、telemetry 埋点；
/// tools 必需，缺省取 ctx.tools。
@ContextTreeActor
@discardableResult
public func provideGoal(_ ctx: Context, config: GoalConfig = GoalConfig()) throws -> any GoalService {
    let resolved: any GoalService
    if let goal = config.goal {
        resolved = goal
    } else {
        resolved = DefaultGoalService(
            session: config.session,
            prompt: config.prompt,
            approval: config.approval,
            telemetry: config.telemetry,
            ctx: ctx,
            defaultMaxRounds: config.defaultMaxRounds
        )
    }
    let registry = try config.tools ?? ctx.require(.tools)
    try ctx.provide(.goal, resolved)
    try ctx.effect { try registry.register(CreateGoalTool(goal: resolved)) }
    try ctx.effect { try registry.register(EditGoalTool(goal: resolved)) }
    try ctx.effect { try registry.register(CompleteGoalTool(goal: resolved)) }
    try ctx.effect { try registry.register(ClearGoalTool(goal: resolved)) }
    attachDriver(ctx, goal: resolved)
    ctx.onDispose { resolved.dispose() }
    return resolved
}

/// goal 与 agentLoop 齐备时创建 GoalRoundDriver 并挂到 AgentLoop.goalDriver
///（依赖消失或上下文释放时自动摘除）。
@ContextTreeActor
private func attachDriver(_ ctx: Context, goal: any GoalService) {
    ctx.inject(deps: [ServiceKey<AgentLoop>.agentLoop.erased]) { child in
        let agent = try child.require(.agentLoop)
        let driver = GoalRoundDriver(goal: goal, agent: agent)
        agent.goalDriver = driver
        try child.provide(.goalRoundDriver, driver)
        child.onDispose { agent.goalDriver = nil }
    }
}
