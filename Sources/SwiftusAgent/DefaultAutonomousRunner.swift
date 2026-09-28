import Foundation
import SwiftusCore
import SwiftusFoundation

/// AutonomousRunner 的默认实现（规格 S16 §8.3）。
///
/// 只负责生命周期：策略持有、run / stop / isRunning 与结果装配；循环主体
/// 委托 AutonomousLoop。**注意**：自主运行时要求 agent 未挂 goalDriver
///（provideGoal 自动挂载的续行驱动器会与 Runner 自己的轮次记账双算）。
@ContextTreeActor
public final class DefaultAutonomousRunner: AutonomousRunner {
    /// 被驱动的 Agent Loop。
    public let agent: AgentLoop
    /// 目标服务。
    public let goal: any GoalService
    /// 绑定的会话（自主 turn 的事件与审计归属）。
    public let session: Session

    private let seams: AutonomousSeams
    private let clock: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private var currentPolicy: any AutonomousPolicy
    private var stopSignal = StopSignal()
    private lazy var loop = AutonomousLoop(
        agent: agent,
        goal: goal,
        session: session,
        policy: { [unowned self] in self.currentPolicy },
        seams: seams,
        clock: clock,
        sleeper: sleeper,
        stopSignal: stopSignal
    )

    /// 是否正在运行。
    public private(set) var isRunning = false
    private var stopped = false

    public init(
        agent: AgentLoop,
        goal: any GoalService,
        session: Session,
        policy: any AutonomousPolicy = DefaultAutonomousPolicy(),
        costTracker: (any CostTracker)? = nil,
        costOfTurn: (@ContextTreeActor (AgentTurn) -> Double)? = nil,
        approval: (any Approval)? = nil,
        telemetry: (any Telemetry)? = nil,
        sessionLog: (any SessionLog)? = nil,
        clock: @escaping @Sendable () -> Date = Date.init,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.agent = agent
        self.goal = goal
        self.session = session
        self.currentPolicy = policy
        seams = AutonomousSeams(
            session: session,
            costTracker: costTracker,
            costOfTurn: costOfTurn,
            approval: approval,
            telemetry: telemetry,
            sessionLog: sessionLog
        )
        self.clock = clock
        self.sleeper = sleeper
    }

    public var policy: any AutonomousPolicy {
        currentPolicy
    }

    public func setPolicy(_ next: any AutonomousPolicy) {
        currentPolicy = next
    }

    public func stop() {
        stopped = true
        stopSignal.signal()
    }

    public func run() async throws -> AutonomousResult {
        guard !isRunning else { throw AutonomousError.alreadyRunning }
        isRunning = true
        stopSignal = StopSignal()
        defer { isRunning = false }
        var turns: [AgentTurn] = []
        var advanced: [String] = []
        var totalCost = 0.0
        var reason: StopReason = .manualStop
        while !stopped {
            let (done, costDelta) = try await loop.iterate(turns: &turns, advanced: &advanced)
            totalCost += costDelta
            if let done {
                reason = done
                break
            }
        }
        // stop() 只影响当次运行（含运行前取消下一次）；结束后复位，runner 可复用。
        stopped = false
        let result = AutonomousResult(
            turns: turns,
            goalsAdvanced: advanced,
            totalCost: totalCost,
            stoppedReason: reason
        )
        await seams.auditFinished(result)
        seams.emitFinished(result)
        return result
    }
}

/// autonomous 装配的输入（参数封装）。
public struct AutonomousConfig {
    /// 策略（缺省 DefaultAutonomousPolicy）。
    public var policy: (any AutonomousPolicy)?
    /// 预算能力缝（缺省无预算限制）。
    public var costTracker: (any CostTracker)?
    /// 每轮成本折算钩子（美元）。
    public var costOfTurn: (@ContextTreeActor (AgentTurn) -> Double)?
    /// 审批缝（缺省自动批准）。
    public var approval: (any Approval)?
    /// 遥测（缺省不埋点）。
    public var telemetry: (any Telemetry)?
    /// 审计日志（缺省不记录）。
    public var sessionLog: (any SessionLog)?
    /// 墙钟（测试注入）。
    public var clock: @Sendable () -> Date = Date.init
    /// 睡眠器（测试注入）。
    public var sleeper: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    public init() {}
}

/// 提供 'autonomousRunner' 服务（规格 S16 §8.3）。
///
/// 未显式传入的可选依赖从上下文惰性解析。
@ContextTreeActor
@discardableResult
public func provideAutonomousRunner(
    _ ctx: Context,
    agent: AgentLoop,
    goal: any GoalService,
    session: Session,
    config: AutonomousConfig = AutonomousConfig()
) throws -> any AutonomousRunner {
    let resolved = DefaultAutonomousRunner(
        agent: agent,
        goal: goal,
        session: session,
        policy: config.policy ?? DefaultAutonomousPolicy(),
        costTracker: config.costTracker ?? ctx.get(.costTracker),
        costOfTurn: config.costOfTurn,
        approval: config.approval ?? ctx.get(.approval),
        telemetry: config.telemetry ?? ctx.get(.telemetry),
        sessionLog: config.sessionLog ?? ctx.get(.sessionLog),
        clock: config.clock,
        sleeper: config.sleeper
    )
    try ctx.provide(.autonomousRunner, resolved)
    return resolved
}

/// 'costTracker' 服务键。
extension ServiceKey where Service == any CostTracker {
    public static let costTracker = ServiceKey<any CostTracker>("costTracker")
}
