import Foundation
import SwiftusCore
import SwiftusFoundation

/// 一轮生命周期追踪端口（规格 S17 §5.1）。
///
/// Task Center 等运行时追踪接入实现本协议，由插件在 `agentLoop` 可用时经
/// `ctx.inject` 后置挂到 `AgentLoop.turnTracker`；未装配时 Agent Loop 行为
/// 与无追踪完全一致。
@ContextTreeActor
public protocol AgentTurnTracker: Sendable {
    /// 一轮开始。
    func beginTurn(_ userInput: String) async throws

    /// 一轮结束；`result` 为最终回复（JSON 形态），`error` 为失败原因
    /// （互斥，可都为空）。
    func endTurn(result: JSONValue?, error: (any Error)?) async throws
}
