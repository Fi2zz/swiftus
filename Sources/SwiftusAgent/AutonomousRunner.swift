import Foundation
import os
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 自主运营的续行提示：Runner 代用户注入的下一轮输入（规格 S16 §8.3）。
public let kAutonomousContinuationPrompt = "[系统] 自主运营：继续推进当前目标。"

/// 自主运行结果。
public struct AutonomousResult: Sendable {
    /// 本轮运行产生的全部轮次（含超时空轮）。
    public let turns: [AgentTurn]
    /// 被推进过的目标 id。
    public let goalsAdvanced: [String]
    /// 累计成本（CostTracker.todayCost 正增量之和；无 tracker 时为 0）。
    public let totalCost: Double
    /// 停止原因。
    public let stoppedReason: StopReason

    public init(turns: [AgentTurn], goalsAdvanced: [String], totalCost: Double, stoppedReason: StopReason) {
        self.turns = turns
        self.goalsAdvanced = goalsAdvanced
        self.totalCost = totalCost
        self.stoppedReason = stoppedReason
    }
}

/// 停止原因。
public enum StopReason: String, Sendable, Equatable {
    /// 正常完成（无目标或目标已终态）。
    case completed
    /// 预算超限。
    case budgetExceeded
    /// 时间窗口结束。
    case windowEnded
    /// 达到最大轮次。
    case maxRoundsReached
    /// 需要人类介入。
    case humanRequired
    /// 手动停止。
    case manualStop
}

/// 自主运行器（规格 S16 §8.3，服务键 'autonomousRunner'）。
@ContextTreeActor
public protocol AutonomousRunner: Sendable {
    /// 启动自主运行。同一时刻只允许一次运行，重复调用抛错。
    func run() async throws -> AutonomousResult

    /// 停止。正在等待时间窗口的睡眠也会被中断，run() 以 manualStop 收尾。
    func stop()

    /// 是否正在运行。
    var isRunning: Bool { get }

    /// 注册策略。
    func setPolicy(_ policy: any AutonomousPolicy)

    /// 当前策略。
    var policy: any AutonomousPolicy { get }
}

/// 运行器错误。
public enum AutonomousError: Error, Equatable {
    /// 已在运行，重复调用 run。
    case alreadyRunning
}

/// 'autonomousRunner' 服务键。
extension ServiceKey where Service == any AutonomousRunner {
    public static let autonomousRunner = ServiceKey<any AutonomousRunner>("autonomousRunner")
}
