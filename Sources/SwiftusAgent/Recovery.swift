import Foundation
import SwiftusCore
import SwiftusFoundation

/// 恢复服务：快照 + 还原（规格 S16 §6.4，服务键 'recovery'）。
@ContextTreeActor
public final class RecoveryService {
    /// 快照存储。
    public let store: any SnapshotStore

    public init(store: any SnapshotStore) {
        self.store = store
    }

    /// 保存一条会话的快照。建议每轮结束或会话释放时调用。
    public func snapshot(_ session: Session) async throws {
        try await store.save(SessionSnapshot(
            sessionId: session.id,
            events: session.events,
            savedAt: Date()
        ))
    }

    /// 载入快照；不存在或版本不符抛 RecoveryError。
    public func load(_ sessionId: String) async throws -> SessionSnapshot {
        guard let snapshot = try await store.load(sessionId) else {
            throw RecoveryError.notFound(sessionId)
        }
        return snapshot
    }

    /// 由快照还原一条会话（带事件种子），可直接交给 Agent Loop 继续对话。
    public func restore(_ sessionId: String) async throws -> Session {
        let snapshot = try await load(sessionId)
        return try Session(id: snapshot.sessionId, seed: snapshot.events)
    }

    /// 已保存快照的会话 id。
    public func list() async throws -> [String] {
        try await store.list()
    }

    /// 删除快照。
    public func delete(_ sessionId: String) async throws {
        try await store.delete(sessionId)
    }
}

/// 'recovery' 服务键。
extension ServiceKey where Service == RecoveryService {
    public static let recovery = ServiceKey<RecoveryService>("recovery")
}

/// 提供 'recovery' 服务（规格 S16 §6.4）。
///
/// 存储优先级：store > 'database' 服务（DatabaseSnapshotStore，W3 后补）> 内存实现。
@ContextTreeActor
@discardableResult
public func provideRecovery(
    _ ctx: Context,
    recovery: RecoveryService? = nil,
    store: (any SnapshotStore)? = nil
) throws -> RecoveryService {
    let resolvedStore = store ?? MemorySnapshotStore()
    let service = recovery ?? RecoveryService(store: resolvedStore)
    try ctx.provide(.recovery, service)
    return service
}
