import Foundation
import SwiftusCore
import SwiftusFoundation

/// 任务中心服务端口（规格 S17 §2，服务键 `tasks`）。
///
/// 只追踪任务状态，不调度也不执行。任务由 Agent Loop / sub-agent / shell /
/// schedule 等运行时组件经追踪装饰器创建。状态机：pending → running ⇄ paused，
/// 任一非终态可转 completed / failed / cancelled（终态不可再变更）。
@ContextTreeActor
public protocol TaskCenter: Sendable {
    /// 创建任务。返回的任务处于 pending 状态。
    @discardableResult
    func create(
        kind: TaskKind,
        description: String,
        parentTaskId: String?,
        metadata: [String: JSONValue]
    ) async throws -> Task

    /// 更新任务状态（规格 S17 §2 update 协议）。
    ///
    /// - status 进入 running 且原 startedAt 为空时自动填入当前时刻；
    /// - status 进入终态时自动填入 finishedAt；
    /// - 终态任务抛 `already-terminal`，任务不存在抛 `not-found`；
    /// - result / error 传空表示不改；结果与原值完全相同时不落盘不广播。
    @discardableResult
    func update(
        _ id: String,
        status: TaskStatus?,
        result: JSONValue?,
        error: JSONValue?
    ) async throws -> Task

    /// 查询单个任务；不存在返回 nil。
    func get(_ id: String) -> Task?

    /// 全部任务（入表顺序）。
    var all: [Task] { get }

    /// 活跃任务（pending + running + paused）。
    var active: [Task] { get }

    /// 指定任务的直接子任务（入表顺序）。
    func children(of parentId: String) -> [Task]

    /// 指定任务的整棵子树（含自己；栈式深度优先，规格 S17 §2）。
    func subtree(of id: String) -> [Task]

    /// 取消任务：级联取消活跃子任务、执行注册过的取消回调；
    /// shell 类任务走 approval 确认（若提供）。拒绝抛 `cancelled`。
    func cancel(_ id: String) async throws

    /// 取消指定任务的所有活跃子任务。不取消自己。
    func cancelChildren(of id: String) async throws

    /// 注册取消回调：cancel 落状态前调用（如 kill 进程）。允许覆盖。
    func registerCancel(_ id: String, canceller: @escaping @ContextTreeActor () async -> Void)

    /// 任务变更流（每次状态落盘后广播最新整值）。
    var changes: AsyncStream<Task> { get }

    /// 从 Session 恢复状态；未完成的活跃任务标记为 failed（执行环境已丢失）。
    func restore(_ session: Session) throws

    /// 释放资源。幂等。
    func dispose()
}

extension TaskCenter {
    /// 创建根任务（无父任务、无元数据）。
    @discardableResult
    public func create(kind: TaskKind, description: String) async throws -> Task {
        try await create(kind: kind, description: description, parentTaskId: nil, metadata: [:])
    }

    /// 创建带元数据的根任务。
    @discardableResult
    public func create(
        kind: TaskKind,
        description: String,
        metadata: [String: JSONValue]
    ) async throws -> Task {
        try await create(kind: kind, description: description, parentTaskId: nil, metadata: metadata)
    }

    /// 只改状态（不带结果与错误）。
    @discardableResult
    public func update(_ id: String, status: TaskStatus) async throws -> Task {
        try await update(id, status: status, result: nil, error: nil)
    }

    /// 改状态与结果（不带错误）。
    @discardableResult
    public func update(_ id: String, status: TaskStatus?, result: JSONValue?) async throws -> Task {
        try await update(id, status: status, result: result, error: nil)
    }
}

/// 'tasks' 服务键。
extension ServiceKey where Service == any TaskCenter {
    public static let tasks = ServiceKey<any TaskCenter>("tasks")
}
