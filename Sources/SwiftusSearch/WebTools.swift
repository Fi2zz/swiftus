import Foundation
import SwiftusCore
import SwiftusCredentials
import SwiftusFoundation

/// web 工具：把搜索与抓取能力暴露给模型（规格 S20 §9）。
///
/// `WebSearchTool` 走 `search` 服务（provider 回退由服务负责）；`FetchUrlTool` 经
/// `WebFetcher` 抓取正文。二者都是 low 风险的只读工具。
@ContextTreeActor
public final class WebSearchTool: Tool {
    private let searchService: SearchService
    /// 未显式传 `limit` 时的默认条数。
    public let defaultLimit: Int

    public init(search: SearchService, defaultLimit: Int = kDefaultSearchLimit) {
        searchService = search
        self.defaultLimit = defaultLimit
    }

    public let name = "web_search"

    public let description = "在互联网上搜索，返回结果的标题、链接与摘要。"

    public let riskLevel: ToolRisk = .low

    public let group: String? = "web"

    public let params: [ParamSpec] = [
        .string("query", description: "搜索关键词", required: true),
        .integer("limit", description: "返回条数"),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        let query = try context.requireString("query")
        let limit = try context.integer("limit") ?? defaultLimit
        let results: [SearchResult]
        do {
            results = try await searchService.search(query, limit: limit)
        } catch {
            let message = unavailableMessage(error)
            return .failure(
                message,
                error: ToolError("SEARCH_UNAVAILABLE", searchFailureMessage(error))
            )
        }
        if results.isEmpty {
            return .success("未找到与 \"\(query)\" 相关的结果", value: .array([]))
        }
        var text = "搜索 \"\(query)\" 的结果："
        for (index, result) in results.enumerated() {
            text += "\n\(index + 1). \(result.title)"
            text += "\n   \(result.url)"
            if !result.snippet.isEmpty { text += "\n   \(result.snippet)" }
        }
        return .success(text, value: .array(results.map { .object($0.json) }))
    }

    /// 明确告知模型「没有联网能力」，并列出没配好的源（规格 S20 §9）。
    private func unavailableMessage(_ error: any Error) -> String {
        var text = "无法联网：所有搜索源都不可用。\n\(searchFailureMessage(error))"
        let skipped = searchService.statuses.filter { !$0.available }
        guard !skipped.isEmpty else { return text }
        text += "\n未配置的搜索源："
        text += skipped.map { "\($0.name)（\($0.reason)）" }.joined(separator: "；")
        return text
    }
}

/// `SearchException` 取 message；其余异常回落到类型描述。
private func searchFailureMessage(_ error: any Error) -> String {
    if let search = error as? SearchException { return search.message }
    if let fetch = error as? FetchException { return fetch.message }
    return String(describing: type(of: error))
}

/// 抓取网页并返回正文（规格 S20 §9）。
@ContextTreeActor
public final class FetchUrlTool: Tool {
    private let fetcher: any WebFetcher
    /// 返回正文的最大字符数（超出截断）。
    public let maxChars: Int

    public init(fetcher: any WebFetcher, maxChars: Int = kFetchDefaultMaxChars) {
        self.fetcher = fetcher
        self.maxChars = maxChars
    }

    /// 当前使用的抓取后端（供测试与诊断）。
    public var backend: any WebFetcher { fetcher }

    public let name = "fetch_url"

    public let description = "抓取一个网页并返回其正文内容。"

    public let riskLevel: ToolRisk = .low

    public let group: String? = "web"

    public let params: [ParamSpec] = [
        .string("url", description: "http(s) 链接", required: true),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        let raw = try context.requireString("url")
        // 只看**协议**（缺主机名由抓取后端判定，见规格 S20 §9）。
        guard let scheme = URLComponents(string: raw)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failure(
                "仅支持 http/https 链接：\"\(raw)\"",
                error: ToolError("INVALID_URL", "unsupported url \"\(raw)\"")
            )
        }
        let page: FetchedPage
        do {
            page = try await fetcher.fetch(raw, maxChars: maxChars)
        } catch let error as FetchException {
            return .failure(
                "无法联网：抓取 \(raw) 失败。\(error.message)",
                error: ToolError("FETCH_FAILED", error.message)
            )
        } catch {
            return .failure(
                "无法联网：抓取 \(raw) 失败。",
                error: ToolError("FETCH_FAILED", String(describing: type(of: error)))
            )
        }
        return .success(
            page.content,
            value: .object(["url": .string(page.url), "format": .string(page.format.rawValue)])
        )
    }
}

/// 把 web 工具注册到 `ctx.tools`，返回已注册的工具（规格 S20 §10）。
///
/// `search` 缺省取上下文的 `search` 服务；`fetcher` 显式给出时优先，否则有
/// `FIRECRAWL_API_KEY` 时用 `FirecrawlFetcher`，都没有则 `HttpFetcher`。
@ContextTreeActor
@discardableResult
public func provideWebTools(
    _ ctx: Context,
    search: SearchService? = nil,
    fetcher: (any WebFetcher)? = nil,
    credentials: Credentials? = nil,
    session: URLSession = .shared,
    tools: ToolRegistry? = nil
) throws -> [any Tool] {
    guard let service = search ?? ctx.get(.search) else {
        throw ContextError.serviceUnavailable(key: "search", context: ctx.name)
    }
    let registry = tools ?? ctx.get(.tools)
    guard let registry else {
        throw ContextError.serviceUnavailable(key: "tools", context: ctx.name)
    }
    let resolvedFetcher = fetcher ?? resolveWebFetcher(ctx, credentials, session)
    let registered: [any Tool] = [
        WebSearchTool(search: service),
        FetchUrlTool(fetcher: resolvedFetcher),
    ]
    for tool in registered {
        try ctx.effect { try registry.register(tool) }
    }
    return registered
}

@ContextTreeActor
private func resolveWebFetcher(
    _ ctx: Context,
    _ credentials: Credentials?,
    _ session: URLSession
) -> any WebFetcher {
    let resolved = credentials ?? ctx.get(.credentials)
    guard let key = resolved?.get(kFirecrawlCredentialKey) else {
        return HttpFetcher(session: session)
    }
    return FirecrawlFetcher(apiKey: key.value, session: session)
}

/// 把 `SearchService` 作为 `search` 服务提供到上下文（规格 S20 §3）。
///
/// 解析顺序：显式 `providers` → 按序注册这些实例并忽略 `order`（`statuses` 为空）；
/// 传入现成的 `search` → 不追加任何 provider；否则按 `order` 构造
/// （`credentials` 缺省取上下文已提供的 `credentials` 服务，两者都没有时只装配免 Key 源）。
@ContextTreeActor
@discardableResult
public func provideSearch(
    _ ctx: Context,
    order: [String] = kDefaultSearchOrder,
    credentials: Credentials? = nil,
    providers: [any SearchProvider]? = nil,
    search: SearchService? = nil,
    session: URLSession = .shared,
    timeout: TimeInterval = 15
) throws -> SearchService {
    var statuses: [SearchSourceStatus] = []
    var toRegister: [any SearchProvider] = []
    if let providers {
        toRegister = providers
        statuses = []
    } else if search != nil {
        toRegister = []
        statuses = []
    } else if let resolved = credentials ?? ctx.get(.credentials) {
        let set = buildSearchProviders(
            order: order, credentials: resolved, session: session, timeout: timeout
        )
        toRegister = set.providers
        statuses = set.statuses
    } else {
        let set = buildKeylessSearchProviders(order: order, session: session, timeout: timeout)
        toRegister = set.providers
        statuses = set.statuses
    }
    let service = search ?? SearchService(statuses: statuses)
    try ctx.provide(.search, service)
    for provider in toRegister {
        // 注册经效应登记：上下文释放即撤销（provider 列表回到空）。
        ctx.effect { service.register(provider) }
    }
    return service
}
