import Foundation
import SwiftusCore
import SwiftusFoundation

/// autonomous 的可选依赖缝及其使用点（规格 S16 §8.3）。
///
/// 集中承载 costTracker / costOfTurn / approval / telemetry / sessionLog
/// 五个可选依赖及全部使用点；缺省降级：不预算限制 / 自动批准 / 不埋点 / 不记录。
@ContextTreeActor
final class AutonomousSeams {
    /// 审计事件归属的会话。
    let session: Session
    /// 预算能力缝；nil 表示无预算限制。
    let costTracker: (any CostTracker)?
    /// 每轮成本折算钩子（美元）；nil 时回退 costTracker 今日增量近似。
    let costOfTurn: (@ContextTreeActor (AgentTurn) -> Double)?
    /// 审批能力缝；nil 表示自动批准。
    let approval: (any Approval)?
    /// 遥测导出器；nil 表示不埋点。
    let telemetry: (any Telemetry)?
    /// 审计日志；nil 表示不记录。
    let sessionLog: (any SessionLog)?

    private let priority = PriorityEngine()

    init(
        session: Session,
        costTracker: (any CostTracker)?,
        costOfTurn: (@ContextTreeActor (AgentTurn) -> Double)?,
        approval: (any Approval)?,
        telemetry: (any Telemetry)?,
        sessionLog: (any SessionLog)?
    ) {
        self.session = session
        self.costTracker = costTracker
        self.costOfTurn = costOfTurn
        self.approval = approval
        self.telemetry = telemetry
        self.sessionLog = sessionLog
    }

    /// 当前累计成本；无 tracker 时为 0。
    var cost: Double {
        costTracker?.todayCost ?? 0
    }

    /// before 之后的正成本增量。
    func costDelta(_ before: Double) -> Double {
        max(0, cost - before)
    }

    /// 一轮成本：有 costOfTurn 钩子用精确折算（负值截 0），否则用今日增量近似。
    func turnCost(_ turn: AgentTurn, before: Double) -> Double {
        guard let hook = costOfTurn else { return costDelta(before) }
        let exact = hook(turn)
        return exact < 0 ? 0 : exact
    }

    /// 经审批确认一次操作；approval 缺省视为自动批准。
    func askApproval(_ toolName: String, _ description: String) async -> Bool {
        guard let gate = approval else { return true }
        return await gate.request(ApprovalRequest(
            id: "autonomous-\(Int(Date().timeIntervalSince1970 * 1_000_000))",
            toolName: toolName,
            description: description
        ))
    }

    /// 记一条 autonomous.* 审计事件；sessionLog 缺失时静默。
    func audit(_ type: String, data: [String: JSONValue]) async {
        guard let log = sessionLog else { return }
        _ = try? await log.append(SessionEvent(
            seq: 0,
            type: type,
            time: Date(),
            data: .object(data),
            id: SessionEventIds.next(),
            sessionId: session.id
        ))
    }

    /// 记一轮结束的审计事件（含决策理由：目标优先级得分）。
    func auditTurn(_ goal: Goal, turn: AgentTurn, costDelta: Double) async {
        await audit("autonomous/turn", data: [
            "goalId": .string(goal.id),
            "priorityScore": .double(priority.scoreOf(goal).score),
            "replyLength": .int(Int64(turn.reply.count)),
            "steps": .int(Int64(turn.steps.count)),
            "costDelta": .double(costDelta),
        ])
    }

    /// 记运行收尾的审计事件。
    func auditFinished(_ result: AutonomousResult) async {
        await audit("autonomous/finished", data: [
            "stoppedReason": .string(result.stoppedReason.rawValue),
            "turns": .int(Int64(result.turns.count)),
            "totalCost": .double(result.totalCost),
            "goalsAdvanced": .int(Int64(result.goalsAdvanced.count)),
        ])
    }

    /// 发一轮结束的埋点事件。
    func emitTurn(_ goal: Goal, turn: AgentTurn, costDelta: Double) {
        telemetry?.emit(TelemetryEvent("autonomous.round", data: [
            "goalId": .string(goal.id),
            "replyLength": .int(Int64(turn.reply.count)),
            "steps": .int(Int64(turn.steps.count)),
            "costDelta": .double(costDelta),
        ]))
    }

    /// 发运行收尾的埋点事件。
    func emitFinished(_ result: AutonomousResult) {
        telemetry?.emit(TelemetryEvent("autonomous.finished", data: [
            "stoppedReason": .string(result.stoppedReason.rawValue),
            "turns": .int(Int64(result.turns.count)),
            "totalCost": .double(result.totalCost),
            "goalsAdvanced": .int(Int64(result.goalsAdvanced.count)),
        ]))
    }
}
