import Foundation
import SwiftusCore

/// 一个已打开的存储单元（规格 S19 §1.3）。
///
/// **权威内存状态 + 写入链 + 变更广播**：每次写入先经后端落盘，成功后才更新内存
/// 并广播，因此读到的内存状态永不领先于介质；后端写失败时内存保持不变、异常原样上抛。
///
/// （Dart 的 `toString` 形如 `DatabaseUnit(u, 3 records)`；本类型是 actor 隔离的
/// 类，`CustomStringConvertible` 的非隔离要求无法满足，故不提供该描述串。）
@ContextTreeActor
public final class DatabaseUnit {
    public let name: String
    private let backend: any DatabaseBackend
    private var state: [String: JSONValue]
    private let onClose: @ContextTreeActor (DatabaseUnit) -> Void
    private var listeners: [(token: Int, body: @ContextTreeActor (DatabaseChange) -> Void)] = []
    private var closedFlag = false
    private var nextToken = 0

    init(
        name: String,
        backend: any DatabaseBackend,
        state: [String: JSONValue],
        onClose: @escaping @ContextTreeActor (DatabaseUnit) -> Void
    ) {
        self.name = name
        self.backend = backend
        self.state = state
        self.onClose = onClose
    }

    /// 是否已关闭。
    public var closed: Bool {
        closedFlag
    }

    /// 记录条数。
    public var length: Int {
        state.count
    }

    /// 全部键（快照）。
    public var keys: [String] {
        Array(state.keys)
    }

    /// 某键是否存在（**值为空也算存在**）。
    public func has(_ key: String) -> Bool {
        state.keys.contains(key)
    }

    /// 读取某键的值；不存在返回 nil。
    public func get(_ key: String) -> JSONValue? {
        state[key]
    }

    /// 全部记录的只读快照（Swift 字典是值类型，返回即拷贝）。
    public var entries: [String: JSONValue] {
        state
    }

    /// 写入一条记录（新增或覆盖）。**落盘成功后才更新内存并广播**。
    public func put(_ key: String, _ value: JSONValue?) async throws {
        try ensureOpen()
        var next = state
        next[key] = value ?? .null
        try await backend.save(name, next)
        state[key] = value ?? .null
        emit(DatabaseChangeKind.put, key, value)
    }

    /// 删除一条记录；不存在返回 false（**不落盘、不广播**）。
    @discardableResult
    public func delete(_ key: String) async throws -> Bool {
        try ensureOpen()
        guard state.keys.contains(key) else { return false }
        var next = state
        next.removeValue(forKey: key)
        try await backend.save(name, next)
        state.removeValue(forKey: key)
        emit(DatabaseChangeKind.deleted, key, nil)
        return true
    }

    /// 监听本单元后续变更，返回注销令牌。
    @discardableResult
    public func onChange(_ body: @escaping @ContextTreeActor (DatabaseChange) -> Void) -> Int {
        nextToken += 1
        listeners.append((token: nextToken, body: body))
        return nextToken
    }

    /// 注销一个变更监听，返回是否确实移除了。
    @discardableResult
    public func removeChangeListener(_ token: Int) -> Bool {
        guard let index = listeners.firstIndex(where: { $0.token == token }) else { return false }
        listeners.remove(at: index)
        return true
    }

    /// 关闭单元：拒绝后续写入并清空监听器；幂等。
    public func close() {
        guard !closedFlag else { return }
        closedFlag = true
        listeners.removeAll()
        onClose(self)
    }

    private func ensureOpen() throws {
        guard !closedFlag else {
            throw DatabaseException(.unitClosed, "单元 \"\(name)\" 已关闭")
        }
    }

    /// 广播变更：按登记顺序遍历监听器快照（先快照再回调，回调里注销不影响本次）。
    private func emit(_ kind: DatabaseChangeKind, _ key: String, _ value: JSONValue?) {
        let change = DatabaseChange(unit: name, key: key, kind: kind, value: value)
        for listener in listeners {
            listener.body(change)
        }
    }
}
