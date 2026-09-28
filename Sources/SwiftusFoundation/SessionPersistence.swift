import Foundation
import SwiftusCore

/// 会话持久化端口（规格 S4 §1）：四个动作，更换后端时消费方代码不变。
///
/// 非隔离 async：落盘 IO 不占用 ContextTreeActor。
public protocol SessionPersistence: Sendable {
    /// 已持久化的会话 id（升序）。
    func list() async throws -> [String]

    /// 载入某会话的全部事件；不存在时返回空列表。
    func load(_ id: String) async throws -> [SessionEvent]

    /// 追加一条事件（append-only，O(1) 行写入）。
    func append(_ id: String, _ event: SessionEvent) async throws

    /// 删除某会话的全部持久化数据。
    func remove(_ id: String) async throws
}

/// 本地 JSONL 实现（规格 S4 §1.1）：一会话一文件，每行一条事件的 JSON。
public struct JsonlSessionPersistence: SessionPersistence {
    /// 会话文件所在目录。
    public let directory: String

    /// dir 缺省为 `<数据根>/sessions`；数据根解析失败时抛 HomeError。
    public init(directory: String? = nil) throws {
        if let directory {
            self.directory = directory
            return
        }
        self.directory = try resolveSwiftusHome() + "/sessions"
    }

    public func list() async throws -> [String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory) else { return [] }
        return try manager.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".jsonl") }
            .map { String($0.dropLast(".jsonl".count)) }
            .sorted()
    }

    /// 逐行载入：空行跳过；一行不是 JSON 对象则跳过（宽容，规格 S4 §1.1）。
    public func load(_ id: String) async throws -> [SessionEvent] {
        let path = filePath(id)
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return text.components(separatedBy: .newlines).compactMap(decodeLine)
    }

    public func append(_ id: String, _ event: SessionEvent) async throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = filePath(id)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        let line = try event.jsonValue.jsonData()
        try handle.write(contentsOf: line)
        try handle.write(contentsOf: [0x0A])
        try handle.synchronize()
    }

    public func remove(_ id: String) async throws {
        let path = filePath(id)
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }

    private func filePath(_ id: String) -> String {
        "\(directory)/\(id).jsonl"
    }

    private func decodeLine(_ line: String) -> SessionEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let value = try? JSONValue.parse(Data(trimmed.utf8)),
              case .object = value else {
            return nil
        }
        return SessionEvent(jsonValue: value)
    }
}

/// 'sessionPersistence' 服务键。
extension ServiceKey where Service == any SessionPersistence {
    public static let sessionPersistence = ServiceKey<any SessionPersistence>("sessionPersistence")
}

/// 将 SessionPersistence 作为 'sessionPersistence' 服务提供到上下文；缺省 JSONL 实现。
@ContextTreeActor
@discardableResult
public func provideSessionPersistence(
    _ ctx: Context,
    persistence: (any SessionPersistence)? = nil
) throws -> any SessionPersistence {
    let resolved = try persistence ?? JsonlSessionPersistence()
    try ctx.provide(.sessionPersistence, resolved)
    return resolved
}
