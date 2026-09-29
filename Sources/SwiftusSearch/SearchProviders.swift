import Foundation
import SwiftusCore

/// Tavily 单次查询的结果数上限（上游限制）。
public let kTavilyMaxResults = 20

/// Tavily 搜索 provider（需 API Key）：面向 LLM 的搜索接口（规格 S20 §5）。
@ContextTreeActor
public final class TavilySearchProvider: SearchProvider {
    public let name = "tavily"
    /// Tavily API Key。
    public let apiKey: String
    /// 单次查询超时。
    public let timeout: TimeInterval

    private let session: URLSession
    private let endpointUrl: String

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: String = "https://api.tavily.com/search",
        timeout: TimeInterval = 15
    ) {
        self.apiKey = apiKey
        self.session = session
        endpointUrl = endpoint
        self.timeout = timeout
    }

    public func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        var request = URLRequest(url: try SearchHttp.endpoint(endpointUrl, provider: name))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        let payload = JSONValue.object([
            "query": .string(query),
            "max_results": .int(Int64(SearchHttp.clamp(limit, kTavilyMaxResults))),
            "search_depth": .string("basic"),
        ])
        request.httpBody = try? payload.jsonData()

        let (data, status) = try await SearchHttp.send(
            request, session: session, timeout: timeout, provider: name
        )
        guard status == 200 else { throw SearchException("\(name) HTTP \(status)") }
        let object = try SearchHttp.decodeObject(data, provider: name)
        return SearchHttp.mapResults(object, snippet: ["content"])
    }
}

/// Exa 搜索 provider（需 API Key）：调用 Exa 的 REST 搜索接口（规格 S20 §5）。
@ContextTreeActor
public final class ExaSearchProvider: SearchProvider {
    public let name = "exa"
    public let apiKey: String
    public let timeout: TimeInterval

    private let session: URLSession
    private let endpointUrl: String

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: String = "https://api.exa.ai/search",
        timeout: TimeInterval = 15
    ) {
        self.apiKey = apiKey
        self.session = session
        endpointUrl = endpoint
        self.timeout = timeout
    }

    public func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        var request = URLRequest(url: try SearchHttp.endpoint(endpointUrl, provider: name))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let payload = JSONValue.object([
            "query": .string(query),
            "numResults": .int(Int64(limit)),
            "contents": .object(["text": .object(["maxCharacters": .int(500)])]),
        ])
        request.httpBody = try? payload.jsonData()

        let (data, status) = try await SearchHttp.send(
            request, session: session, timeout: timeout, provider: name
        )
        guard status == 200 else { throw SearchException("\(name) HTTP \(status)") }
        let object = try SearchHttp.decodeObject(data, provider: name)
        // text 缺失时回落 summary（规格 S20 §5）。
        return SearchHttp.mapResults(object, snippet: ["text", "summary"])
    }
}

/// Brave 单次查询的结果数上限（上游限制）。
public let kBraveMaxCount = 20

/// Brave 搜索 provider（需 API Key）：调用 Brave 的 web search 接口（规格 S20 §5）。
@ContextTreeActor
public final class BraveSearchProvider: SearchProvider {
    public let name = "brave"
    public let apiKey: String
    public let timeout: TimeInterval

    private let session: URLSession
    private let endpointUrl: String

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: String = "https://api.search.brave.com/res/v1/web/search",
        timeout: TimeInterval = 15
    ) {
        self.apiKey = apiKey
        self.session = session
        endpointUrl = endpoint
        self.timeout = timeout
    }

    public func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        let base = try SearchHttp.endpoint(endpointUrl, provider: name)
        let url = SearchHttp.url(base, query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "\(SearchHttp.clamp(limit, kBraveMaxCount))"),
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-subscription-token")

        let (data, status) = try await SearchHttp.send(
            request, session: session, timeout: timeout, provider: name
        )
        guard status == 200 else { throw SearchException("\(name) HTTP \(status)") }
        let object = try SearchHttp.decodeObject(data, provider: name)
        // `web` 缺失 → 空列表（不是失败）；`description` 经标记清洗。
        guard let web = object["web"]?.objectValue else { return [] }
        return SearchHttp.mapResults(
            web, container: "results", snippet: ["description"], cleanSnippet: true
        )
    }
}

/// 常见浏览器 UA，降低被拦概率。
public let kDuckDuckGoUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

/// DuckDuckGo 搜索 provider（无需 Key）：抓取 html 端点并解析结果（规格 S20 §5 / §7）。
///
/// HTML 解析是尽力而为的最佳努力（上游结构可能变化），但 provider 失败会抛
/// `SearchException`，由 `SearchService` 回退到下一个 provider。
@ContextTreeActor
public final class DuckDuckGoSearchProvider: SearchProvider {
    public let name = "duckduckgo"
    public let timeout: TimeInterval

    private let session: URLSession
    private let endpointUrl: String

    public init(
        session: URLSession = .shared,
        endpoint: String = "https://html.duckduckgo.com/html/",
        timeout: TimeInterval = 15
    ) {
        self.session = session
        endpointUrl = endpoint
        self.timeout = timeout
    }

    public func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        let base = try SearchHttp.endpoint(endpointUrl, provider: name)
        let url = SearchHttp.url(base, query: [URLQueryItem(name: "q", value: query)])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(kDuckDuckGoUserAgent, forHTTPHeaderField: "user-agent")

        let (data, status) = try await SearchHttp.send(
            request, session: session, timeout: timeout, provider: name
        )
        guard status == 200 else { throw SearchException("\(name) HTTP \(status)") }
        return DuckDuckGoHtml.parse(String(decoding: data, as: UTF8.self), limit: limit)
    }
}
