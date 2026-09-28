import Foundation
import SwiftusCore

/// session log 的内存后端（规格 S4 §3.1）：进程内的多会话事件日志。
/// 适合测试与短生命周期进程；进程退出即丢失。
@ContextTreeActor
public final class InMemorySessionLog: SessionLog {
    private var sessions: [String: [SessionEvent]] = [:]
    private var forks: [String: Int] = [:]

    /// 是否已关闭。
    public private(set) var closed = false

    public init() {}

    @discardableResult
    public func append(_ event: SessionEvent) throws -> SessionEvent {
        let sessionId = try requireEventSessionId(event)
        var events = sessions[sessionId] ?? []
        var stamped = event
        stamped.sessionId = sessionId
        stamped.seq = events.count
        events.append(stamped)
        sessions[sessionId] = events
        return stamped
    }

    public func read(_ sessionId: String, from: Date? = nil, to: Date? = nil) -> [SessionEvent] {
        (sessions[sessionId] ?? []).filter { eventInWindow($0, from: from, to: to) }
    }

    @discardableResult
    public func fork(_ sessionId: String, fromEventId: String, newId: String? = nil) throws -> String {
        let prefix = try eventPrefix(sessions[sessionId] ?? [], fromEventId: fromEventId)
        let target = newId ?? nextForkId(sessionId, counters: &forks)
        sessions[target] = restampPrefix(prefix, newSessionId: target)
        return target
    }

    public func replay(_ sessionId: String, handler: @Sendable (SessionEvent) -> Void) {
        for event in sessions[sessionId] ?? [] {
            handler(event)
        }
    }

    public func list() -> [String] {
        sessions.keys.sorted()
    }

    public func close() {
        closed = true
        sessions.removeAll()
        forks.removeAll()
    }
}

/// session log 的持久化后端（规格 S4 §3.2）：复用 append-only 的 SessionPersistence。
/// 追加写入 O(1)（一会话一文件，逐行 append），长会话下没有写放大。
@ContextTreeActor
public final class PersistenceSessionLog: SessionLog {
    /// 底层持久化端口。
    public let persistence: any SessionPersistence

    private var forks: [String: Int] = [:]
    private var seqs: [String: Int] = [:]

    public init(_ persistence: any SessionPersistence) {
        self.persistence = persistence
    }

    @discardableResult
    public func append(_ event: SessionEvent) async throws -> SessionEvent {
        let sessionId = try requireEventSessionId(event)
        var stamped = event
        stamped.sessionId = sessionId
        stamped.seq = try await takeSeq(sessionId)
        try await persistence.append(sessionId, stamped)
        return stamped
    }

    public func read(_ sessionId: String, from: Date? = nil, to: Date? = nil) async throws -> [SessionEvent] {
        try await persistence.load(sessionId).filter { eventInWindow($0, from: from, to: to) }
    }

    @discardableResult
    public func fork(_ sessionId: String, fromEventId: String, newId: String? = nil) async throws -> String {
        let prefix = try eventPrefix(await persistence.load(sessionId), fromEventId: fromEventId)
        let target = newId ?? nextForkId(sessionId, counters: &forks)
        for event in restampPrefix(prefix, newSessionId: target) {
            try await persistence.append(target, event)
        }
        return target
    }

    public func replay(_ sessionId: String, handler: @Sendable (SessionEvent) -> Void) async throws {
        for event in try await persistence.load(sessionId) {
            handler(event)
        }
    }

    public func list() async throws -> [String] {
        try await persistence.list()
    }

    public func close() async {}

    /// 分配该会话的下一个 seq（首次使用时从已落盘的事件数续接）。
    private func takeSeq(_ sessionId: String) async throws -> Int {
        if let cached = seqs[sessionId] {
            seqs[sessionId] = cached + 1
            return cached
        }
        let seq = try await persistence.load(sessionId).count
        seqs[sessionId] = seq + 1
        return seq
    }
}

/// 'sessionLog' 服务键。
extension ServiceKey where Service == any SessionLog {
    public static let sessionLog = ServiceKey<any SessionLog>("sessionLog")
}

/// 将 SessionLog 作为 'sessionLog' 服务提供到上下文（规格 S4 §3.3 装配优先级）：
/// 显式 log → persistence（或 'sessionPersistence' 服务）→ 进程内 InMemorySessionLog。
/// （database 档位属 W3 database 能力域，后补。）上下文释放时关闭日志。
@ContextTreeActor
@discardableResult
public func provideSessionLog(
    _ ctx: Context,
    log: (any SessionLog)? = nil,
    persistence: (any SessionPersistence)? = nil
) throws -> any SessionLog {
    let resolved = try log ?? resolveBackend(ctx, persistence: persistence)
    try ctx.provide(.sessionLog, resolved)
    ctx.onDispose {
        Task { await resolved.close() }
    }
    return resolved
}

@ContextTreeActor
private func resolveBackend(_ ctx: Context, persistence: (any SessionPersistence)?) throws -> any SessionLog {
    if let store = persistence ?? ctx.get(.sessionPersistence) {
        return PersistenceSessionLog(store)
    }
    return InMemorySessionLog()
}
