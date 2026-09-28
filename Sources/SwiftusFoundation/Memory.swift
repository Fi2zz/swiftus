import Foundation
import SwiftusCore

/// 一条长记忆（规格 S13 §1）。
public struct MemoryEntry: Sendable, Equatable {
    /// 记忆标识。
    public let id: String
    /// 记忆正文。
    public let text: String
    /// 标签（参与召回打分）。
    public let tags: Set<String>
    /// 创建时间。
    public let createdAt: Date

    public init(id: String, text: String, tags: Set<String> = [], createdAt: Date) {
        self.id = id
        self.text = text
        self.tags = tags
        self.createdAt = createdAt
    }

    /// 从 JSONValue 宽容反序列化（tags 缺省空、createdAt 解析失败退回当前时刻）。
    public init(jsonValue: JSONValue) {
        let object = jsonValue.objectValue ?? [:]
        id = object["id"]?.stringValue ?? ""
        text = object["text"]?.stringValue ?? ""
        tags = Set(object["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        if let raw = object["createdAt"]?.stringValue,
           let parsed = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            createdAt = parsed
        } else {
            createdAt = Date()
        }
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "text": .string(text),
            "createdAt": .string(createdAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))),
        ]
        if !tags.isEmpty {
            object["tags"] = .array(tags.sorted().map { .string($0) })
        }
        return .object(object)
    }
}

/// 长记忆存储端口（规格 S13 §1）：整表快照式——载入 / 覆盖保存。
public protocol MemoryBackend: Sendable {
    /// 载入全部记忆。
    func load() async throws -> [MemoryEntry]

    /// 覆盖保存全部记忆。
    func save(_ entries: [MemoryEntry]) async throws
}

/// 纯内存实现：进程退出即丢失，用作默认后端与测试替身。
@ContextTreeActor
public final class InMemoryMemoryBackend: MemoryBackend {
    private var stored: [MemoryEntry] = []

    public init() {}

    public func load() async -> [MemoryEntry] {
        stored
    }

    public func save(_ entries: [MemoryEntry]) async {
        stored = entries
    }
}

/// 本地 JSON 实现（规格 S13 §1）：整表写入一个文件。
public struct JsonMemoryBackend: MemoryBackend {
    /// 记忆文件路径。
    public let filePath: String

    public init(filePath: String) {
        self.filePath = filePath
    }

    public func load() async throws -> [MemoryEntry] {
        guard FileManager.default.fileExists(atPath: filePath) else { return [] }
        let text = try String(contentsOfFile: filePath, encoding: .utf8)
        guard let value = try? JSONValue.parse(Data(text.utf8)), case let .array(items) = value else {
            return []
        }
        return items.map(MemoryEntry.init(jsonValue:))
    }

    public func save(_ entries: [MemoryEntry]) async throws {
        let data = try JSONValue.array(entries.map(\.jsonValue)).jsonData()
        try FileManager.default.createDirectory(
            atPath: (filePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }
}
