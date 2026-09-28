import Foundation
import SwiftusCore
import SwiftusFoundation

/// 目标服务（规格 S16 §7.2，服务键 'goal'）。
///
/// 只存目标状态，不调度工作。工具、命令、续行驱动器是三个独立的消费端，
/// 都读同一份状态。状态机：active 可转 paused / blocked / completed；
/// paused 与 blocked 可 resume 回 active；clear 从任意状态转 cleared（终态）。
@ContextTreeActor
public protocol GoalService: Sendable {
    /// 当前会话的目标（至多一个）。无目标时返回 nil。
    var current: Goal? { get }

    /// 创建目标。已有非终态目标时抛 GoalException（already_exists）。
    @discardableResult
    func create(_ text: String, maxRounds: Int?) async throws -> Goal

    /// 编辑目标文本。仅 active / paused 状态可编辑。
    @discardableResult
    func edit(_ text: String) async throws -> Goal

    /// 暂停。仅 active 可暂停。
    @discardableResult
    func pause() async throws -> Goal

    /// 恢复。paused / blocked 回到 active（清除阻塞原因）。
    @discardableResult
    func resume() async throws -> Goal

    /// 标记完成（终态）。走 approval 确认（若提供）。
    @discardableResult
    func complete() async throws -> Goal

    /// 标记阻塞。仅 active / paused 可阻塞。
    @discardableResult
    func block(_ reason: String) async throws -> Goal

    /// 清除目标（终态）。走 approval 确认（若提供）。
    @discardableResult
    func clear() async throws -> Goal

    /// 递增轮次。超过 maxRounds 时自动 block。
    func advanceRound() async throws

    /// 状态变更流。
    var changes: AsyncStream<Goal> { get }

    /// 从 Session 恢复状态。
    func restore(_ session: Session)

    /// 释放资源。幂等。
    func dispose()
}

/// 'goal' 服务键。
extension ServiceKey where Service == any GoalService {
    public static let goal = ServiceKey<any GoalService>("goal")
}
