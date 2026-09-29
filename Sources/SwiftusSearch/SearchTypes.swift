import Foundation
import SwiftusCore

/// 一条搜索结果（规格 S20 §1）。
public struct SearchResult: Sendable, Equatable {
    /// 结果标题。
    public let title: String
    /// 结果链接。
    public let url: String
    /// 摘要（可为空串）。
    public let snippet: String

    public init(title: String, url: String, snippet: String = "") {
        self.title = title
        self.url = url
        self.snippet = snippet
    }

    /// 序列化为 JSON（三个键，与来源一致）。
    public var json: [String: JSONValue] {
        ["title": .string(title), "url": .string(url), "snippet": .string(snippet)]
    }
}

/// 搜索 provider 契约（规格 S20 §1）。
///
/// 实现只负责**一次查询**，失败抛 `SearchException`；回退链由 `SearchService` 编排。
/// 协议显式标 `Sendable`：全局 actor 协议的 existential 不自动 Sendable（见 HANDOFF）。
@ContextTreeActor
public protocol SearchProvider: AnyObject, Sendable {
    /// provider 名（诊断与显式路由）。
    var name: String { get }

    /// 查询 `query`，最多返回 `limit` 条结果。
    func search(_ query: String, limit: Int) async throws -> [SearchResult]
}

extension SearchProvider {
    /// 缺省条数（规格 S20 §1：provider 契约的 `limit` 缺省 5）。
    ///
    /// 协议方法不允许默认参数（编译期限制），故走扩展重载。
    public func search(_ query: String) async throws -> [SearchResult] {
        try await search(query, limit: kDefaultSearchLimit)
    }
}

/// 缺省返回条数。
public let kDefaultSearchLimit = 5

/// 搜索失败（规格 S20 §1）：**只有消息、没有错误码**，消息即契约。
public struct SearchException: Error, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

extension SearchException: CustomStringConvertible {
    /// 与来源的 `toString()` 同形（`SearchException: <message>`）——
    /// 回退链的聚合文案里嵌的就是它（规格 S20 §2）。
    public var description: String {
        "SearchException: \(message)"
    }
}

/// 装配期状态：某个源是否可用及原因（规格 S20 §4）。
public struct SearchSourceStatus: Sendable, Equatable {
    /// 源名。
    public let name: String
    /// 是否成功装配。
    public let available: Bool
    /// 不可用原因（可用时为空串）。
    public let reason: String

    public init(name: String, available: Bool, reason: String = "") {
        self.name = name
        self.available = available
        self.reason = reason
    }

    /// JSON 投影。
    public var json: [String: JSONValue] {
        ["name": .string(name), "available": .bool(available), "reason": .string(reason)]
    }
}

/// 搜索源凭据键名（规格 S20 §1）。
public let kTavilyCredentialKey = "TAVILY_API_KEY"
public let kExaCredentialKey = "EXA_API_KEY"
public let kBraveCredentialKey = "BRAVE_API_KEY"
public let kFirecrawlCredentialKey = "FIRECRAWL_API_KEY"
