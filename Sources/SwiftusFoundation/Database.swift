import Foundation
import SwiftusCore

/// 带稳定错误码的 database 异常（规格 S19 §1.1）。
public struct DatabaseException: Error, Equatable {
    /// 机器可路由的错误码。
    public enum Code: String, Sendable, Equatable {
        case invalidBackend = "invalid-backend"
        case duplicateBackend = "duplicate-backend"
        case backendNotFound = "backend-not-found"
        case invalidUnit = "invalid-unit"
        case alreadyOpen = "already-open"
        case noBackend = "no-backend"
        case unitClosed = "unit-closed"
        case malformedMedium = "malformed-medium"
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

extension DatabaseException: CustomStringConvertible {
    public var description: String {
        "DatabaseException(\(code.rawValue)): \(message)"
    }
}

/// 一次单元变更的类型。
public enum DatabaseChangeKind: String, Sendable, Equatable {
    case put, deleted
}

/// 一次**已落盘**的单元变更：在持久化成功且内存更新之后广播（规格 S19 §1.1）。
public struct DatabaseChange: Sendable, Equatable {
    public let unit: String
    public let key: String
    public let kind: DatabaseChangeKind
    /// `put` 时的新值；`deleted` 时为 nil。
    public let value: JSONValue?

    public init(unit: String, key: String, kind: DatabaseChangeKind, value: JSONValue?) {
        self.unit = unit
        self.key = key
        self.kind = kind
        self.value = value
    }
}

extension DatabaseChange: CustomStringConvertible {
    public var description: String {
        "DatabaseChange(\(kind.rawValue), \(unit)/\(key))"
    }
}

/// 具名存储后端：拥有一个介质（如一棵文件树），按单元整表读写（规格 S19 §1.1）。
///
/// 每次调用都是原子的，返回即已落盘；**后端不负责并发排序**，由单元写入链保证。
@ContextTreeActor
public protocol DatabaseBackend: AnyObject, Sendable {
    /// 载入某单元的整表；单元不存在时返回空表。
    func load(_ unit: String) async throws -> [String: JSONValue]

    /// 覆盖保存某单元的整表。
    func save(_ unit: String, _ records: [String: JSONValue]) async throws

    /// 删除某单元的全部数据。
    func deleteUnit(_ unit: String) async throws

    /// 关闭后端、释放介质；幂等。
    func close() async
}

/// 存储 hub：后端注册表与已打开单元表（规格 S19 §1.2，服务键 `database`）。
///
/// hub 本身**不做 IO**：后端拥有介质，`open(unit)` 从后端载入整表并返回单元句柄。
/// 多个后端可并排注册，由每次 `open` 的路由选择。
@ContextTreeActor
public final class Database {
    /// 缺省后端名；`open` 未指定路由时使用。
    public var defaultBackend: String?

    /// 后端登记项：`token` 区分同名注册的先后（撤销只认自己那一次）。
    private struct BackendEntry {
        let name: String
        let token: Int
        let backend: any DatabaseBackend
    }

    private var backends: [BackendEntry] = []
    private var units: [(name: String, unit: DatabaseUnit)] = []
    private var seq = 0

    public init(defaultBackend: String? = nil) {
        self.defaultBackend = defaultBackend
    }

    /// 已注册的后端名（**注册顺序**）。
    public var backendNames: [String] {
        backends.map(\.name)
    }

    /// 已打开的单元名（**打开顺序**）。
    public var unitNames: [String] {
        units.map(\.name)
    }

    /// 已打开的单元数。
    public var count: Int {
        units.count
    }

    /// 注册一个具名后端；重名或空名抛 `DatabaseException`；返回幂等的撤销函数。
    ///
    /// 撤销只移除**自己注册的那一次**——同名被重注册后，过期撤销函数不得误删新后端。
    @discardableResult
    public func register(_ name: String, _ backend: any DatabaseBackend) throws -> Disposer {
        guard !name.isEmpty else {
            throw DatabaseException(.invalidBackend, "后端名不能为空")
        }
        if backends.contains(where: { $0.name == name }) {
            throw DatabaseException(.duplicateBackend, "后端 \"\(name)\" 已注册")
        }
        seq += 1
        let token = seq
        backends.append(BackendEntry(name: name, token: token, backend: backend))
        var removed = false
        return { [weak self] in
            guard let self, !removed else { return }
            removed = true
            guard let index = self.backends.firstIndex(where: { $0.name == name }),
                  self.backends[index].token == token else { return }
            self.backends.remove(at: index)
        }
    }

    /// 解析一个后端；未注册抛 `backend-not-found`。
    public func backend(_ name: String) throws -> any DatabaseBackend {
        guard let found = backends.first(where: { $0.name == name }) else {
            throw DatabaseException(.backendNotFound, "后端 \"\(name)\" 未注册")
        }
        return found.backend
    }

    /// 打开一个单元：从路由后端载入整表并返回句柄（规格 S19 §1.2）。
    public func open(_ unit: String, backend: String? = nil) async throws -> DatabaseUnit {
        guard !unit.isEmpty else {
            throw DatabaseException(.invalidUnit, "单元名不能为空")
        }
        if units.contains(where: { $0.name == unit }) {
            throw DatabaseException(.alreadyOpen, "单元 \"\(unit)\" 已打开")
        }
        let resolved = try resolveBackend(backend)
        let state = try await resolved.load(unit)
        let handle = DatabaseUnit(name: unit, backend: resolved, state: state) { [weak self] closed in
            self?.units.removeAll { $0.name == closed.name }
        }
        units.append((name: unit, unit: handle))
        return handle
    }

    /// 查找已打开的单元；未打开返回 nil。
    public func get(_ unit: String) -> DatabaseUnit? {
        units.first { $0.name == unit }?.unit
    }

    /// 关闭某单元；返回是否确实关闭了一个。
    @discardableResult
    public func close(_ unit: String) -> Bool {
        guard let handle = get(unit) else { return false }
        handle.close()
        return true
    }

    /// 关闭全部单元。
    public func closeAll() {
        for entry in units.reversed() {
            entry.unit.close()
        }
        units.removeAll()
    }

    /// 路由解析：显式名 > `defaultBackend` > 仅一个已注册后端。
    private func resolveBackend(_ name: String?) throws -> any DatabaseBackend {
        if let name = name ?? defaultBackend {
            return try backend(name)
        }
        if backends.count == 1 {
            return backends[0].backend
        }
        throw DatabaseException(.noBackend, "未指定后端且注册的后端不唯一")
    }
}

extension ServiceKey where Service == Database {
    public static let database = ServiceKey<Database>("database")
}

/// 将 `Database` 作为 `database` 服务提供到上下文（规格 S19 §1.2）。
@ContextTreeActor
@discardableResult
public func provideDatabase(_ ctx: Context, database: Database? = nil, defaultBackend: String? = nil) throws -> Database {
    let hub = database ?? Database(defaultBackend: defaultBackend)
    try ctx.provide(.database, hub)
    ctx.onDispose { hub.closeAll() }
    return hub
}
