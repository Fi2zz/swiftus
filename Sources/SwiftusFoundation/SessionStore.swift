import Foundation
import SwiftusCore

/// 会话仓库错误（规格 S4 §2）。
public enum SessionStoreError: Error, Equatable {
    /// 同 id 会话已活跃。
    case duplicateSession(String)
}

/// 会话仓库（规格 S4 §2，服务键 `sessions`）：进程内持有活跃会话，并可选地
/// 接线持久化。打开会话时从持久化载入既有事件作为种子（不重复落盘），之后每次
/// 追加都异步入链写入；`flush()` 等待所有在途写入落定并暴露首个失败。
@ContextTreeActor
public final class SessionStore {
    private let persistence: (any SessionPersistence)?
    private var sessions: [String: Session] = [:]
    private var writeChain: Task<Void, Never>?
    private var writeErrors: [any Error] = []

    public init(persistence: (any SessionPersistence)? = nil) {
        self.persistence = persistence
    }

    /// 活跃会话 id。
    public var ids: [String] {
        Array(sessions.keys)
    }

    /// 活跃会话数。
    public var length: Int {
        sessions.count
    }

    /// 查找活跃会话；未打开返回 nil。
    public func get(_ id: String) -> Session? {
        sessions[id]
    }

    /// 创建新会话；id 缺省时自动生成。同 id 重复创建抛 SessionStoreError。
    @discardableResult
    public func create(id: String? = nil) throws -> Session {
        let resolved = id ?? "session_\(newUuidV4())"
        guard sessions[resolved] == nil else {
            throw SessionStoreError.duplicateSession(resolved)
        }
        let session = try Session(id: resolved)
        attach(session)
        sessions[resolved] = session
        return session
    }

    /// 注册一个外部创建的会话（如 fork 的产物）进仓库（规格 S4 §2.1 adopt）。
    ///
    /// 接有持久化时先把**全部种子事件**落盘（fork 的继承历史不能在重开时丢失），
    /// 再接后续追加写入与关闭清理。同 id 已活跃抛 SessionStoreError。
    @discardableResult
    public func adopt(_ session: Session) throws -> Session {
        guard sessions[session.id] == nil else {
            throw SessionStoreError.duplicateSession(session.id)
        }
        for event in session.events {
            enqueueWrite(session.id, event)
        }
        attach(session)
        sessions[session.id] = session
        return session
    }

    /// 打开会话：已活跃则直接返回，否则从持久化载入事件作为种子。
    public func open(_ id: String) async throws -> Session {
        if let active = sessions[id] {
            return active
        }
        let seed = try await persistence?.load(id) ?? []
        let session = try Session(id: id, seed: seed)
        attach(session)
        sessions[id] = session
        return session
    }

    /// 关闭并移除活跃会话。返回是否确实移除了一个。
    @discardableResult
    public func close(_ id: String) -> Bool {
        guard let session = sessions.removeValue(forKey: id) else { return false }
        session.close()
        return true
    }

    /// 关闭并删除某会话的持久化数据。返回是否有东西被处理。
    @discardableResult
    public func remove(_ id: String) async throws -> Bool {
        let closed = close(id)
        if let persistence {
            try await persistence.remove(id)
        }
        return closed || persistence != nil
    }

    /// 已持久化的会话 id（未接持久化时为空）。
    public func persistedIds() async throws -> [String] {
        try await persistence?.list() ?? []
    }

    /// 等待所有在途的持久化写入落定；任一在途写入失败时抛出首个失败（规格 S4 §2.2）。
    public func flush() async throws {
        await writeChain?.value
        guard let first = writeErrors.first else { return }
        writeErrors.removeAll()
        throw first
    }

    /// 接线：追加事件入链落盘；关闭时从活跃表移除。
    private func attach(_ session: Session) {
        session.onEvent { [weak self] event in
            self?.enqueueWrite(session.id, event)
        }
        session.onClose { [weak self] in
            self?.sessions.removeValue(forKey: session.id)
        }
    }

    /// 写入链串行化（规格 S4 §2.2）：同一进程内的落盘写入串行执行，避免并发写
    /// 同一文件丢事件；链上吞错不卡后续写入，原始错误保留供 flush 暴露。
    private func enqueueWrite(_ id: String, _ event: SessionEvent) {
        guard let persistence else { return }
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            do {
                try await persistence.append(id, event)
            } catch {
                self?.recordWriteError(error)
            }
        }
    }

    private func recordWriteError(_ error: any Error) {
        writeErrors.append(error)
    }
}

/// 'sessions' 服务键。
extension ServiceKey where Service == SessionStore {
    public static let sessions = ServiceKey<SessionStore>("sessions")
}

/// 将 SessionStore 作为 'sessions' 服务提供到上下文（规格 S4 §2）。
/// 未显式传入 persistence 时复用上下文里已提供的 'sessionPersistence'。
@ContextTreeActor
@discardableResult
public func provideSessions(
    _ ctx: Context,
    sessions: SessionStore? = nil,
    persistence: (any SessionPersistence)? = nil
) throws -> SessionStore {
    let resolved = persistence ?? ctx.get(.sessionPersistence)
    let store = sessions ?? SessionStore(persistence: resolved)
    try ctx.provide(.sessions, store)
    return store
}
