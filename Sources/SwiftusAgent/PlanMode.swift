import Foundation
import SwiftusCore
import SwiftusFoundation

/// Plan Mode 变更事件类型（规格 S16 §9.1）。
public let kPlanModeEvent = "plan/mode"

/// `plan:policy` 段文本（规格 S16 §9.1）：只提 web_search 与 ask_user，
/// 不提读本地文件（语音优先场景）。
public let kPlanModePolicy = "You are in plan mode. Use web_search and ask_user to gather "
    + "information before presenting a complete plan through "
    + "exit_plan_mode. Do not execute mutating operations until the "
    + "plan is approved."

/// Plan Mode 状态。
public enum PlanModeState: String, Sendable, Equatable {
    case inactive
    case active
}

/// Plan Mode 服务端口（规格 S16 §9.2，服务键 'planMode'）。
@ContextTreeActor
public protocol PlanMode: Sendable {
    /// 当前状态。
    var state: PlanModeState { get }

    /// 进入 Plan Mode。
    func enter()

    /// 退出 Plan Mode。由审批通过后调用。
    func exit()

    /// 提交计划供审批。返回用户是否批准。
    func submitPlan(_ plan: Plan) async -> Bool

    /// 状态变更流。
    var changes: AsyncStream<PlanModeState> { get }

    /// 释放资源。幂等。
    func dispose()
}

/// 'planMode' 服务键。
extension ServiceKey where Service == any PlanMode {
    public static let planMode = ServiceKey<any PlanMode>("planMode")
}

/// 折叠会话自身后缀里最后一个 plan/mode 事件，还原 Plan Mode 状态
///（规格 S16 §9.1）。
@ContextTreeActor
public func restorePlanModeState(_ session: Session) -> PlanModeState {
    for event in session.ownEvents.reversed() where event.type == kPlanModeEvent {
        guard let data = event.data, case .object = data else { continue }
        if data["state"]?.stringValue == "active" {
            return .active
        }
        return .inactive
    }
    return .inactive
}
