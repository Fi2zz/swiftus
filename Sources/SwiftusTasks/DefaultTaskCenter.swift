import Foundation
import os
import SwiftusAgent
import SwiftusCore
import SwiftusFoundation

/// 任务中心的默认实现（规格 S17 §3）：内存任务表 + 可选 Session 持久化。
///
/// 把任务状态接到三个能力缝上：`session` 持久化 `task/changed` 事件（整值替换，
/// 恢复时按 id 折叠最后一个）、`approval` shell 类任务取消确认（缺省不拦）、
/// `telemetry` 埋点（`task.*` 事件）。全部可选，缺省时降级。
@ContextTreeActor
public final class DefaultTaskCenter: TaskCenter {
    private let context: Context?
    private var session: Session?
    private var approval: (any Approval)?
    private var telemetry: (any Telemetry)?
    private var stored: [String: Task] = [:]
    private var insertionOrder: [String] = []
    private var cancellers: [String: @ContextTreeActor () async -> Void] = [:]
    private var seq = 0
    private var disposed = false
    private let clock: @Sendable () -> Date

    private struct State {
        var subscribers: [UUID: AsyncStream<Task>.Continuation] = [:]
        var closed = false
    }

    private let broadcast = OSAllocatedUnfairLock<State>(initialState: State())

    /// 各 seam 显式传入优先；缺省时从 ctx 惰性解析；再缺省则降级。
    /// 提供 session 时构造即自动恢复。
    ///
    /// 构造可抛错：恢复出的任务事件若 `createdAt` 非法则抛
    /// `TaskError.invalidCreatedAt`（规格 S17 §1）。
    public init(
        session: Session? = nil,
        approval: (any Approval)? = nil,
        telemetry: (any Telemetry)? = nil,
        ctx: Context? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.session = session
        self.approval = approval
        self.telemetry = telemetry
        self.clock = clock
        context = ctx
        if let resolved = resolveSession() {
            try restore(resolved)
        }
    }

    public var changes: AsyncStream<Task> {
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

    // ══════════════════════════════════════════════════════════════
    // 状态机
    // ══════════════════════════════════════════════════════════════

    @discardableResult
    public func create(
        kind: TaskKind,
        description: String,
        parentTaskId: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) async throws -> Task {
        try ensureOpen()
        seq += 1
        let now = clock()
        let task = Task(
            id: "task-\(seq)-\(taskMicroseconds(now))",
            kind: kind,
            status: .pending,
            description: description,
            createdAt: now,
            parentTaskId: parentTaskId,
            metadata: metadata
        )
        store(task)
        try persist(task)
        emit("task.created", task)
        publish(task)
        return task
    }

    @discardableResult
    public func update(
        _ id: String,
        status: TaskStatus? = nil,
        result: JSONValue? = nil,
        error: JSONValue? = nil
    ) async throws -> Task {
        try ensureOpen()
        guard let existing = stored[id] else { throw TaskError.notFound(id: id) }
        if existing.isTerminal { throw TaskError.alreadyTerminal(id: id) }
        let now = clock()
        var updated = existing
        if status == .running, existing.startedAt == nil {
            updated = updated.copyWith(startedAt: now)
        }
        if let status, status != existing.status {
            updated = updated.copyWith(status: status)
            if updated.isTerminal {
                updated = updated.copyWith(finishedAt: now)
            }
        }
        if let result { updated = updated.copyWith(result: result) }
        if let error { updated = updated.copyWith(error: error) }
        guard updated != existing else { return existing }
        store(updated)
        try persist(updated)
        emitTransition(from: existing, to: updated)
        publish(updated)
        return updated
    }

    public func get(_ id: String) -> Task? {
        stored[id]
    }

    public var all: [Task] {
        insertionOrder.compactMap { stored[$0] }
    }

    public var active: [Task] {
        all.filter(\.isActive)
    }

    public func children(of parentId: String) -> [Task] {
        all.filter { $0.parentTaskId == parentId }
    }

    public func subtree(of id: String) -> [Task] {
        var result: [Task] = []
        var frontier = [id]
        while let current = frontier.popLast() {
            if let task = stored[current] {
                result.append(task)
            }
            frontier.append(contentsOf: children(of: current).map(\.id))
        }
        return result
    }

    public func cancel(_ id: String) async throws {
        try ensureOpen()
        guard let task = stored[id] else { throw TaskError.notFound(id: id) }
        if task.isTerminal { throw TaskError.alreadyTerminal(id: id) }
        try await confirmCancel(task)
        try await cancelChildren(of: id)
        if let canceller = cancellers.removeValue(forKey: id) {
            await canceller()
        }
        let cancelled = task.copyWith(status: .cancelled, finishedAt: clock())
        store(cancelled)
        try persist(cancelled)
        emit("task.cancelled", cancelled)
        publish(cancelled)
    }

    public func cancelChildren(of id: String) async throws {
        for child in children(of: id) where child.isActive {
            try await cancel(child.id)
        }
    }

    public func registerCancel(_ id: String, canceller: @escaping @ContextTreeActor () async -> Void) {
        cancellers[id] = canceller
    }

    public func restore(_ session: Session) throws {
        self.session = session
        let restored = try restoreTaskState(session)
        stored.removeAll()
        insertionOrder.removeAll()
        for task in restored {
            store(task)
        }
        for task in restored where task.isActive {
            let stale = task.copyWith(
                status: .failed,
                finishedAt: clock(),
                error: .string(kTaskStaleReason)
            )
            store(stale)
            try persist(stale)
            emit("task.failed", stale)
            publish(stale)
        }
    }

    public func dispose() {
        guard !disposed else { return }
        disposed = true
        cancellers.removeAll()
        // 锁内只取出订阅者、锁外再 finish：finish() 会同步触发 onTermination，
        // 而 onTermination 回调要再进同一把锁（OSAllocatedUnfairLock 不可重入，
        // 锁内 finish 会触发 _os_unfair_lock_recursive_abort）。
        let subscribers: [AsyncStream<Task>.Continuation] = broadcast.withLock { current in
            current.closed = true
            let alive = Array(current.subscribers.values)
            current.subscribers.removeAll()
            return alive
        }
        for subscriber in subscribers {
            subscriber.finish()
        }
    }

    // ══════════════════════════════════════════════════════════════
    // 能力缝
    // ══════════════════════════════════════════════════════════════

    private func resolveSession() -> Session? {
        // Swift 侧 Session 非上下文服务，仅显式传入（对齐 DefaultPlanMode 的同款取舍）。
        session
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

    // ══════════════════════════════════════════════════════════════
    // 落盘 / 埋点 / 广播
    // ══════════════════════════════════════════════════════════════

    private func store(_ task: Task) {
        if stored[task.id] == nil {
            insertionOrder.append(task.id)
        }
        stored[task.id] = task
    }

    private func persist(_ task: Task) throws {
        try resolveSession()?.append(kTaskEvent, data: task.jsonValue)
    }

    private func emit(_ name: String, _ task: Task) {
        resolveTelemetry()?.emit(TelemetryEvent(name, data: [
            "id": .string(task.id),
            "kind": .string(task.kind.rawValue),
            "status": .string(task.status.rawValue),
            "description": .string(task.description),
        ]))
    }

    private func emitTransition(from previous: Task, to current: Task) {
        switch (previous.status, current.status) {
        case (.pending, .running):
            emit("task.started", current)
        case (.paused, .running):
            emit("task.resumed", current)
        case (.running, .paused):
            emit("task.paused", current)
        case (_, .completed):
            emit("task.completed", current)
        case (_, .failed):
            emit("task.failed", current)
        default:
            break
        }
    }

    /// 广播一次变更：锁内只取订阅者快照，yield 在锁外做（yield 可能同步触发
    /// 消费者的 onTermination，而它要再进同一把锁——同 dispose 的坑）。
    private func publish(_ task: Task) {
        let subscribers: [AsyncStream<Task>.Continuation] = broadcast.withLock { current in
            guard !current.closed else { return [] }
            return Array(current.subscribers.values)
        }
        for subscriber in subscribers {
            subscriber.yield(task)
        }
    }

    /// shell 类任务取消前的审批确认（规格 S17 §2 cancel ②）。
    private func confirmCancel(_ task: Task) async throws {
        guard let approval = resolveApproval(), task.kind == .shell else { return }
        let granted = await approval.request(ApprovalRequest(
            id: "cancel-\(task.id)",
            toolName: kCancelTasksToolName,
            arguments: [
                "id": .string(task.id),
                "description": .string(task.description),
            ],
            description: "取消任务「\(task.description)」？"
        ))
        guard granted else { throw TaskError.cancelled }
    }

    private func ensureOpen() throws {
        guard !disposed else { throw TaskError.disposed }
    }
}

/// 墙钟微秒（任务 id 的时间戳部分）。
private func taskMicroseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
}
