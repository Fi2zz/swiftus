import Foundation
import SwiftusCore

/// 本地 JSON 文件后端（规格 S19 §1.4）：每单元一个人类可读的 JSON 文件，
/// 整表**临时文件 + rename 原子发布**；载入时把非对象内容判为 `malformed-medium`。
@ContextTreeActor
public final class JsonDatabaseBackend: DatabaseBackend {
    /// 单元文件所在目录。
    public let dir: String

    public init(dir: String? = nil) {
        self.dir = dir ?? Self.defaultDir()
    }

    public func load(_ unit: String) async throws -> [String: JSONValue] {
        let file = try Self.file(in: dir, unit: unit)
        guard FileManager.default.fileExists(atPath: file) else { return [:] }
        guard let data = FileManager.default.contents(atPath: file) else { return [:] }
        guard let json = try? JSONValue.parse(data) else {
            throw DatabaseException(.malformedMedium, "单元 \"\(unit)\" 的文件不是 JSON 对象")
        }
        guard let object = json.objectValue else {
            throw DatabaseException(.malformedMedium, "单元 \"\(unit)\" 的文件不是 JSON 对象")
        }
        return object
    }

    public func save(_ unit: String, _ records: [String: JSONValue]) async throws {
        let file = try Self.file(in: dir, unit: unit)
        let directory = (file as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoded = try JSONValue.object(records).jsonData()
        let temp = file + ".tmp-\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        try encoded.write(to: URL(fileURLWithPath: temp))
        do {
            try FileManager.default.moveItem(atPath: temp, toPath: file)
        } catch {
            // rename 目标已存在等情形：退化为直接覆盖并清理临时文件。
            try encoded.write(to: URL(fileURLWithPath: file))
            try? FileManager.default.removeItem(atPath: temp)
        }
    }

    public func deleteUnit(_ unit: String) async throws {
        let file = try Self.file(in: dir, unit: unit)
        guard FileManager.default.fileExists(atPath: file) else { return }
        try FileManager.default.removeItem(atPath: file)
    }

    public func close() async {}

    /// 单元名必须是安全文件名：空或含路径分隔符即 `invalid-unit`。
    static func file(in dir: String, unit: String) throws -> String {
        guard !unit.isEmpty, !unit.contains("/"), !unit.contains("\\") else {
            throw DatabaseException(.invalidUnit, "非法单元名 \"\(unit)\"")
        }
        return dir + "/" + unit + ".json"
    }

    /// 缺省目录：macOS 走 `<swiftus home>/database`；iOS 无 home 目录概念
    /// （`homeDirectoryForCurrentUser` 在 iOS 不可用），改落沙盒内的
    /// Application Support/database。
    static func defaultDir() -> String {
        #if os(macOS)
        let home = (try? resolveSwiftusHome()) ?? FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/database"
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "database").path
        #endif
    }
}

/// 把 `JsonDatabaseBackend` 注册到 hub 的 `database` 服务上（规格 S19 §1.4）。
@ContextTreeActor
@discardableResult
public func provideDatabaseJson(
    _ ctx: Context,
    database: Database? = nil,
    name: String = "json",
    dir: String? = nil
) throws -> JsonDatabaseBackend {
    let hub = try database ?? ctx.require(.database)
    let backend = JsonDatabaseBackend(dir: dir)
    let off = try hub.register(name, backend)
    ctx.onDispose {
        // Disposer 可抛（撤销不应失败），此处按「释放路径不抛」收口。
        try? off()
    }
    // 后端本身无资源（close 为空实现），随上下文撤销注册即可。
    return backend
}
