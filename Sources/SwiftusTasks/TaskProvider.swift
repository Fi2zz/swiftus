import Foundation
import SwiftusAgent
import SwiftusCore
import SwiftusFoundation

/// 任务中心装配的输入（参数封装）。
public struct TaskCenterConfig {
    /// 显式服务实例（优先）。
    public var taskCenter: (any TaskCenter)?
    /// 任务持久化到的会话。
    public var session: Session?
    /// shell 类任务取消确认端口。
    public var approval: (any Approval)?
    /// 遥测埋点。
    public var telemetry: (any Telemetry)?
    /// 工具注册表（缺省取上下文）。
    public var tools: ToolRegistry?
    /// 是否注册模型可见工具。
    public var registerTools = true
    /// 墙钟取样缝（任务 id 与各时间戳的来源）。
    public var clock: @Sendable () -> Date

    public init() {
        clock = Date.init
    }
}

/// 提供 `tasks` 服务并注册任务工具（规格 S17 §6）。
///
/// 依赖（全部可选，缺省时降级）：`session` 持久化 `task/changed` 事件、
/// `approval` shell 类任务取消确认、`telemetry` 埋点；`tools` 缺省取
/// `ctx.tools`。
@ContextTreeActor
@discardableResult
public func provideTaskCenter(_ ctx: Context, config: TaskCenterConfig = TaskCenterConfig()) throws -> any TaskCenter {
    let resolved: any TaskCenter
    if let taskCenter = config.taskCenter {
        resolved = taskCenter
    } else {
        resolved = try DefaultTaskCenter(
            session: config.session,
            approval: config.approval,
            telemetry: config.telemetry,
            ctx: ctx,
            clock: config.clock
        )
    }
    let registry = try config.tools ?? ctx.require(.tools)
    try ctx.provide(.tasks, resolved)
    if config.registerTools {
        try ctx.effect { try registry.register(ListTasksTool(taskCenter: resolved)) }
        try ctx.effect { try registry.register(CancelTaskTool(taskCenter: resolved)) }
    }
    ctx.onDispose { resolved.dispose() }
    return resolved
}

/// 挂载运行时追踪：`spawn_agent` 中间件 + Agent Loop 轮次钩子（规格 S17 §6）。
///
/// `tasks` 缺省取 `ctx.tasks`；`registry` 缺省取 `ctx.tools`。`agentLoop`
/// 尚不可用时经依赖注入等待，就绪即挂载、消失即摘除。
@ContextTreeActor
@discardableResult
public func provideTaskTracking(
    _ ctx: Context,
    tasks: (any TaskCenter)? = nil,
    registry: ToolRegistry? = nil
) throws -> TaskTracking {
    let resolved = try tasks ?? ctx.require(.tasks)
    let target = try registry ?? ctx.require(.tools)
    let tracking = TaskTracking(tasks: resolved, ctx: ctx)
    ctx.effect {
        let token = target.use(tracking.spawnAgentMiddleware)
        let disposer: Disposer = { target.removePipelineListener(token) }
        return disposer
    }
    ctx.inject(deps: [ServiceKey<AgentLoop>.agentLoop.erased]) { child in
        let agent = try child.require(.agentLoop)
        agent.turnTracker = tracking
        child.onDispose {
            if (agent.turnTracker as AnyObject?) === (tracking as AnyObject) {
                agent.turnTracker = nil
            }
        }
    }
    return tracking
}
