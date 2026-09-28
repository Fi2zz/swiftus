import Foundation
import SwiftusCore
import SwiftusFoundation

/// 会话本地的提醒服务（规格 S8 §11.1，服务键 `schedule`）。
///
/// 提醒没有独立存储：唯一权威是会话里的 `schedule/change` 事件，因此会话落盘后
/// 重启即可自动重建全部活动提醒。读取与决策前会先等待一次持久化检查点；创建与
/// 删除在追加之后还会等待第二次检查点，无法确认时抛 SchedulePersistenceError，
/// 而不是声称成功。
@ContextTreeActor
public final class SessionSchedule {
    /// 被管理的会话。
    public let session: Session

    /// 持久化检查点缝（S8 实现注记：SessionStore 落 S4 + Agent 步骤，届时适配进此缝）。
    private let flushStore: (() async throws -> Void)?

    private let clock: @Sendable () -> Date

    /// 构造服务；`flush` 缺省时没有持久化检查点；`clock` 注入墙钟采样。
    public init(
        session: Session,
        flush: (() async throws -> Void)? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        flushStore = flush
        self.clock = clock
    }

    /// 采样当前墙钟。
    public func now() -> Date {
        clock()
    }

    /// 折叠出当前的活动提醒与用过的标识（只读 ownEvents：fork 不继承活动提醒）。
    public func fold() throws -> ScheduleFold {
        try foldScheduleEvents(session.ownEvents)
    }

    /// 等待一次持久化检查点；没有存储后端时立即返回。
    public func checkpoint(_ operation: ScheduleOperation, id: String? = nil) async throws {
        guard let flushStore else { return }
        do {
            try await flushStore()
        } catch {
            throw SchedulePersistenceError(operation: operation, id: id)
        }
    }

    /// 按创建顺序列出全部活动提醒。
    public func list() async throws -> [ScheduleView] {
        try await checkpoint(ScheduleOperation.list)
        let at = now()
        return try fold().active.map { scheduleView($0, at) }
    }

    /// 创建一条提醒；三个选择器互斥，由调用方保证只给一个（规格 S8 §11.1）。
    @discardableResult
    public func create(
        prompt: String,
        afterSeconds: Int? = nil,
        at: JSONValue? = nil,
        everySeconds: Int? = nil
    ) async throws -> ScheduleView {
        try await checkpoint(ScheduleOperation.create)
        let id = allocateScheduleId(try fold())
        let createdAt = now()
        let record = try makeRecord(
            id: id,
            prompt: prompt,
            afterSeconds: afterSeconds,
            at: at,
            everySeconds: everySeconds,
            now: createdAt
        )
        try session.append(kScheduleChangeEvent, data: createPayload(record))
        try await checkpoint(ScheduleOperation.create, id: id)
        return scheduleView(record, now())
    }

    /// 删除一条活动提醒；目标不存在时返回 deleted: false 且不改动任何状态。
    public func delete(_ id: String) async throws -> ScheduleDeleteResult {
        try await checkpoint(ScheduleOperation.delete, id: id)
        guard try fold().find(id) != nil else {
            return ScheduleDeleteResult(id: id, deleted: false)
        }
        try session.append(kScheduleChangeEvent, data: .object([
            "version": .int(Int64(kScheduleChangeVersion)),
            "operation": .string("delete"),
            "id": .string(id),
        ]))
        try await checkpoint(ScheduleOperation.delete, id: id)
        return ScheduleDeleteResult(id: id, deleted: true)
    }

    /// 把一次派发写入历史；固定间隔派发必须带 acceptedAt（规格 S8 §6）。
    public func recordDispatch(_ id: String, acceptedAt: Date? = nil) throws {
        var data: [String: JSONValue] = [
            "version": .int(Int64(kScheduleChangeVersion)),
            "operation": .string("dispatch"),
            "id": .string(id),
        ]
        if let acceptedAt {
            data["acceptedAt"] = .string(formatUtcInstant(acceptedAt))
        }
        try session.append(kScheduleChangeEvent, data: .object(data))
    }

    /// 三选一分支：at 优先于 afterSeconds 优先于 everySeconds（规格 S8 §11.1）。
    private func makeRecord(
        id: String,
        prompt: String,
        afterSeconds: Int?,
        at: JSONValue?,
        everySeconds: Int?,
        now: Date
    ) throws -> ScheduleRecord {
        if let at {
            return try createAtRecord(id: id, prompt: prompt, at: at, now: now)
        }
        if let afterSeconds {
            return try createAfterRecord(id: id, prompt: prompt, afterSeconds: afterSeconds, now: now)
        }
        guard let everySeconds else {
            throw ScheduleInputError(.invalidRule, "every_seconds must be a safe integer.")
        }
        return try createEveryRecord(id: id, prompt: prompt, everySeconds: everySeconds, now: now)
    }

    private func createPayload(_ record: ScheduleRecord) -> JSONValue {
        .object([
            "version": .int(Int64(kScheduleChangeVersion)),
            "operation": .string("create"),
            "schedule": record.jsonValue,
        ])
    }
}

/// 'schedule' 服务键。
extension ServiceKey where Service == SessionSchedule {
    public static let schedule = ServiceKey<SessionSchedule>("schedule")
}

/// 把 SessionSchedule 作为 `schedule` 服务提供到上下文（规格 S8 §11.1）。
@ContextTreeActor
@discardableResult
public func provideSessionSchedule(
    _ ctx: Context,
    session: Session,
    flush: (() async throws -> Void)? = nil,
    clock: @escaping @Sendable () -> Date = Date.init
) throws -> SessionSchedule {
    let schedule = SessionSchedule(session: session, flush: flush, clock: clock)
    try ctx.provide(.schedule, schedule)
    return schedule
}
