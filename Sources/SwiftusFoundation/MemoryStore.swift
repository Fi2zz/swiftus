import Foundation
import SwiftusCore

/// 长记忆库服务（规格 S13 §2，服务键 'memory'）。
///
/// 记忆以自由文本存入，召回时按查询词元与记忆文本/标签的重叠数打分
///（英文按词、中文按二元组切分），同分按新旧排序。超过 maxEntries 时逐出最旧。
@ContextTreeActor
public final class MemoryStore {
    /// 容量上限，超出时逐出最旧的一条。
    public let maxEntries: Int

    private let backend: any MemoryBackend
    private var entries: [MemoryEntry] = []
    private var listeners: [UUID: @ContextTreeActor () -> Void] = [:]
    private var didLoad = false
    private var seq = 0
    private var lastCreatedAt: Date?

    /// maxEntries 为负时快速失败。
    public init(maxEntries: Int = 1000, backend: (any MemoryBackend)? = nil) throws {
        guard maxEntries >= 0 else {
            throw MemoryError.negativeLimit(maxEntries)
        }
        self.maxEntries = maxEntries
        self.backend = backend ?? InMemoryMemoryBackend()
    }

    /// 当前记忆（加载后）。
    public var allEntries: [MemoryEntry] {
        entries
    }

    /// 记忆条数。
    public var length: Int {
        entries.count
    }

    /// 是否已从后端加载。
    public var loaded: Bool {
        didLoad
    }

    /// 从后端加载记忆；幂等（仅首次真正读；读到非空时清空重建并广播）。
    public func load() async throws {
        guard !didLoad else { return }
        didLoad = true
        let fetched = try await backend.load()
        guard !fetched.isEmpty else { return }
        entries.removeAll()
        entries.append(contentsOf: fetched)
        notify()
    }

    /// 记住一段文本，返回新条目。首次调用会自动 load。
    @discardableResult
    public func remember(_ text: String, tags: Set<String> = []) async throws -> MemoryEntry {
        try await load()
        seq += 1
        let entry = MemoryEntry(
            id: "memory-\(Int(Date().timeIntervalSince1970 * 1_000_000))-\(seq)",
            text: text,
            tags: tags,
            createdAt: nextCreatedAt()
        )
        entries.append(entry)
        govern()
        try await backend.save(entries)
        notify()
        return entry
    }

    /// 按关键词召回（规格 S13 §2）：按得分降序、同分新→旧，取前 limit 条。
    /// 只看已加载的记忆；需要读盘时先 load。
    public func recall(_ query: String, limit: Int = 5) -> [MemoryEntry] {
        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty, limit > 0 else { return [] }
        var scored: [(entry: MemoryEntry, score: Int)] = []
        for entry in entries {
            let score = scoreOf(entry, queryTokens: queryTokens)
            if score > 0 {
                scored.append((entry, score))
            }
        }
        scored.sort { left, right in
            if left.score != right.score {
                return left.score > right.score
            }
            return left.entry.createdAt > right.entry.createdAt
        }
        return scored.prefix(limit).map(\.entry)
    }

    /// 按 id 遗忘一条；返回是否确实删除。首次调用会自动 load。
    @discardableResult
    public func forget(_ id: String) async throws -> Bool {
        try await load()
        let before = entries.count
        entries.removeAll { $0.id == id }
        guard entries.count != before else { return false }
        try await backend.save(entries)
        notify()
        return true
    }

    /// 按正文完全一致遗忘，返回删除条数。
    @discardableResult
    public func forgetByText(_ text: String) async throws -> Int {
        try await forgetWhere { $0.text == text }
    }

    /// 按正文包含 query（不区分大小写）遗忘；query 去空白后为空则不动。
    @discardableResult
    public func forgetMatching(_ query: String) async throws -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return 0 }
        return try await forgetWhere { $0.text.lowercased().contains(needle) }
    }

    /// 清空全部记忆。
    public func clear() async throws {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        try await backend.save(entries)
        notify()
    }

    /// 监听记忆变更。返回幂等撤销。
    @discardableResult
    public func onChange(_ listener: @escaping @ContextTreeActor () -> Void) -> Disposer {
        let token = UUID()
        listeners[token] = listener
        return { [weak self] in
            self?.listeners.removeValue(forKey: token)
        }
    }

    private func scoreOf(_ entry: MemoryEntry, queryTokens: Set<String>) -> Int {
        let entryTokens = Self.tokenize("\(entry.text) \(entry.tags.joined(separator: " "))")
        return queryTokens.filter { entryTokens.contains($0) }.count
    }

    /// 容量治理：超限时循环删 createdAt 最早的一条（同时间取先加入者）。
    private func govern() {
        while entries.count > maxEntries {
            var oldest = 0
            for index in 1..<entries.count where entries[index].createdAt < entries[oldest].createdAt {
                oldest = index
            }
            entries.remove(at: oldest)
        }
    }

    private func forgetWhere(_ test: (MemoryEntry) -> Bool) async throws -> Int {
        try await load()
        let before = entries.count
        entries.removeAll(where: test)
        let deleted = before - entries.count
        guard deleted > 0 else { return 0 }
        try await backend.save(entries)
        notify()
        return deleted
    }

    /// createdAt 单调化：系统时钟精度不足（同微秒）时前推 1μs，
    /// 保证同分排序的「新→旧」与 Dart 微秒级 DateTime 一致（规格 S13 注记）。
    private func nextCreatedAt() -> Date {
        let now = Date()
        if let last = lastCreatedAt, now <= last {
            let advanced = last.addingTimeInterval(0.000_001)
            lastCreatedAt = advanced
            return advanced
        }
        lastCreatedAt = now
        return now
    }

    private func notify() {
        for listener in Array(listeners.values) {
            listener()
        }
    }

    /// 词元化（规格 S13 §3）：小写后——[a-z0-9]+ 连续段各一词元；
    /// 中文连续段按二元组切分（长度 1 单独成词元，否则每相邻两字一个词元）。
    static func tokenize(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        var tokens = Set<String>()
        for match in lower.matches(of: /[a-z0-9]+/) {
            tokens.insert(String(match.output))
        }
        for match in lower.matches(of: /[\u{4e00}-\u{9fff}]+/) {
            let run = String(match.output)
            let characters = Array(run)
            if characters.count == 1 {
                tokens.insert(run)
                continue
            }
            for index in 0..<(characters.count - 1) {
                tokens.insert(String(characters[index]) + String(characters[index + 1]))
            }
        }
        return tokens
    }
}

/// 记忆库配置错误。
public enum MemoryError: Error, Equatable {
    /// maxEntries 为负。
    case negativeLimit(Int)
}

/// 'memory' 服务键。
extension ServiceKey where Service == MemoryStore {
    public static let memory = ServiceKey<MemoryStore>("memory")
}

/// 将 MemoryStore 作为 'memory' 服务提供到上下文（规格 S13 §4）。
@ContextTreeActor
@discardableResult
public func provideMemory(
    _ ctx: Context,
    memory: MemoryStore? = nil,
    backend: (any MemoryBackend)? = nil
) throws -> MemoryStore {
    let resolved = try memory ?? MemoryStore(backend: backend ?? InMemoryMemoryBackend())
    try ctx.provide(.memory, resolved)
    return resolved
}
