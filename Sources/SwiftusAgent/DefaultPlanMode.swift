import Foundation
import os
import SwiftusCore
import SwiftusFoundation

/// PlanMode 的默认实现（规格 S16 §9.2）。
///
/// 把状态变更接到四个能力缝上：session 持久化 plan/mode 事件、systemPrompt
/// 注入/撤销 plan:policy 段、approval 审批计划（缺省自动批准）、telemetry 埋点。
/// 全部可选，缺省时降级。
@ContextTreeActor
public final class DefaultPlanMode: PlanMode {
    private let context: Context?
    private var session: Session?
    private var prompt: SystemPrompt?
    private var approval: (any Approval)?
    private var telemetry: (any Telemetry)?
    private var currentState: PlanModeState = .inactive
    private var policyDisposer: Disposer?
    private var disposed = false

    private struct State {
        var subscribers: [UUID: AsyncStream<PlanModeState>.Continuation] = [:]
        var closed = false
    }

    private let broadcast = OSAllocatedUnfairLock<State>(initialState: State())

    /// 各 seam 显式传入优先；缺省时从 ctx 惰性解析；再缺省则降级。
    public init(
        session: Session? = nil,
        prompt: SystemPrompt? = nil,
        approval: (any Approval)? = nil,
        telemetry: (any Telemetry)? = nil,
        ctx: Context? = nil
    ) {
        self.session = session
        self.prompt = prompt
        self.approval = approval
        self.telemetry = telemetry
        context = ctx
        if let resolved = resolveSession(),
           restorePlanModeState(resolved) == .active {
            currentState = .active
            attachPolicy()
        }
    }

    public var state: PlanModeState {
        currentState
    }

    public var changes: AsyncStream<PlanModeState> {
        AsyncStream { continuation in
            let token = UUID()
            broadcast.withLock { current -> Void in
                if current.closed {
                    continuation.finish()
                } else {
                    current.subscribers[token] = continuation
                }
            }
            continuation.onTermination = { [broadcast] _ in
                broadcast.withLock { current -> Void in
                    current.subscribers.removeValue(forKey: token)
                }
            }
        }
    }

    public func enter() {
        guard currentState != .active, !disposed else { return }
        attachPolicy()
        _ = try? resolveSession()?.append(kPlanModeEvent, data: .object(["state": .string("active")]))
        currentState = .active
        publish(.active)
        resolveTelemetry()?.emit(TelemetryEvent("plan.entered"))
    }

    public func exit() {
        guard currentState == .active else { return }
        if let disposer = policyDisposer {
            try? disposer()
        }
        policyDisposer = nil
        _ = try? resolveSession()?.append(kPlanModeEvent, data: .object(["state": .string("inactive")]))
        currentState = .inactive
        publish(.inactive)
        resolveTelemetry()?.emit(TelemetryEvent("plan.exited"))
    }

    /// 注册 plan:policy 段（重复调用先撤销旧段，幂等）。
    func attachPolicy() {
        guard let prompt = resolvePrompt() else { return }
        if let disposer = policyDisposer {
            try? disposer()
        }
        policyDisposer = try? prompt.section(PromptSection(name: "plan:policy", order: 100, text: { kPlanModePolicy }))
    }

    public func submitPlan(_ plan: Plan) async -> Bool {
        resolveTelemetry()?.emit(TelemetryEvent("plan.submitted", data: [
            "goal": .string(plan.goal),
            "steps": .int(Int64(plan.steps.count)),
        ]))
        guard let gate = resolveApproval() else { return true }
        return await gate.requestPlan(plan)
    }

    public func dispose() {
        guard !disposed else { return }
        disposed = true
        if currentState == .active {
            exit()
        }
        let subscribers: [AsyncStream<PlanModeState>.Continuation] = broadcast.withLock { current in
            current.closed = true
            let alive = Array(current.subscribers.values)
            current.subscribers.removeAll()
            return alive
        }
            // 锁内只取出订阅者、锁外再 finish：finish() 会同步触发 onTermination，
            // 而 onTermination 要再进同一把锁（OSAllocatedUnfairLock 不可重入）。
        for subscriber in subscribers {
            subscriber.finish()
        }
    }

    private func publish(_ next: PlanModeState) {
        broadcast.withLock { current -> Void in
            guard !current.closed else { return }
            for subscriber in current.subscribers.values {
                subscriber.yield(next)
            }
        }
    }

    private func resolveSession() -> Session? {
        // Swift 侧 Session 非上下文服务，仅显式传入（对齐 Dart 的显式分支）。
        session
    }

    private func resolvePrompt() -> SystemPrompt? {
        if let prompt { return prompt }
        let resolved = context?.get(.systemPrompt)
        prompt = resolved
        return resolved
    }

    private func resolveApproval() -> (any Approval)? {
        if let approval { return approval }
        let resolved = context?.get(.approval)
        approval = resolved
        return resolved
    }

    private func resolveTelemetry() -> (any Telemetry)? {
        if let telemetry { return telemetry }
        let resolved = context?.get(.telemetry)
        telemetry = resolved
        return resolved
    }
}

/// 提供 'planMode' 服务，注册 exit_plan_mode 工具并挂拦截中间件
///（规格 S16 §9.2）。
@ContextTreeActor
@discardableResult
public func providePlanMode(
    _ ctx: Context,
    planMode: (any PlanMode)? = nil,
    session: Session? = nil,
    prompt: SystemPrompt? = nil,
    approval: (any Approval)? = nil,
    tools: ToolRegistry? = nil,
    telemetry: (any Telemetry)? = nil
) throws -> any PlanMode {
    let resolved = planMode ?? DefaultPlanMode(
        session: session,
        prompt: prompt,
        approval: approval,
        telemetry: telemetry,
        ctx: ctx
    )
    let registry = try tools ?? ctx.require(.tools)
    try ctx.provide(.planMode, resolved)
    try ctx.effect { try registry.register(ExitPlanModeTool(planMode: resolved)) }
    blockMutations(ctx, registry, planMode: resolved)
    ctx.onDispose { resolved.dispose() }
    return resolved
}

/// Plan Mode 激活时拒绝 riskLevel >= medium 的工具调用（规格 S16 §9.2）。
@ContextTreeActor
private func blockMutations(_ ctx: Context, _ registry: ToolRegistry, planMode: any PlanMode) {
    ctx.effect {
        let token = registry.use { call, next in
            guard planMode.state == .active else { return try await next() }
            guard let tool = registry.get(call.name), tool.riskLevel >= .medium else {
                return try await next()
            }
            return .failure(
                "Plan mode is active. Please submit a plan through exit_plan_mode first.",
                error: ToolError("PLAN_MODE_BLOCKED", "plan mode is active")
            )
        }
        let disposer: Disposer = {
            registry.removePipelineListener(token)
        }
        return disposer
    }
}
