import Foundation
import SwiftusCore
import SwiftusCredentials
import SwiftusFoundation
import SwiftusSearch
import Testing

/// S20 单元测试：fixtures 够不到的缝——**超时文案**、**上下文装配与撤销**、
/// **凭据驱动的源选择**、**无凭据降级**。
@Suite("S20 装配与超时")
struct S20AssemblyTests {
    @Test("provider 超时文案带源名与秒数")
    @ContextTreeActor
    func providerTimeoutMessage() async throws {
        let session = S20StubProtocol.sessionFailing(.timedOut)
        let endpoint = "https://timeout.test/search"
        let providers: [any SearchProvider] = [
            TavilySearchProvider(apiKey: "k", session: session, endpoint: endpoint, timeout: 7),
            ExaSearchProvider(apiKey: "k", session: session, endpoint: endpoint, timeout: 7),
            BraveSearchProvider(apiKey: "k", session: session, endpoint: endpoint, timeout: 7),
            DuckDuckGoSearchProvider(session: session, endpoint: endpoint, timeout: 7),
        ]
        for provider in providers {
            let expected = provider.name
            do {
                _ = try await provider.search("q", limit: 1)
                Issue.record("\(expected) 应当超时抛错")
            } catch let error as SearchException {
                #expect(error.message == "\(expected) 请求超时（7s）")
            }
        }
    }

    @Test("抓取超时的两种文案")
    @ContextTreeActor
    func fetchTimeoutMessage() async throws {
        let session = S20StubProtocol.sessionFailing(.timedOut)
        do {
            _ = try await HttpFetcher(session: session, timeout: 11).fetch("https://e.test/p")
            Issue.record("HttpFetcher 应当超时抛错")
        } catch let error as FetchException {
            #expect(error.message == "请求超时（11s）")
        }
        do {
            _ = try await FirecrawlFetcher(
                apiKey: "f", session: session, endpoint: "https://f.test/scrape", timeout: 22
            ).fetch("https://e.test/p")
            Issue.record("FirecrawlFetcher 应当超时抛错")
        } catch let error as FetchException {
            #expect(error.message == "Firecrawl 请求超时（22s）")
        }
    }

    @Test("服务经 `search` 键暴露；上下文释放撤销全部注册")
    @ContextTreeActor
    func contextLifecycle() async throws {
        let ctx = Context.root()
        try ctx.provide(.tools, ToolRegistry())
        let service = try provideSearch(
            ctx,
            credentials: InMemoryCredentials(initial: ["EXA_API_KEY": "e"]),
            session: s20Session()
        )
        #expect(ctx.get(.search) === service)
        #expect(service.registeredNames == ["exa", "duckduckgo"])
        let tools = try provideWebTools(ctx, session: s20Session())
        #expect(tools.map(\.name) == ["web_search", "fetch_url"])
        let registry = try #require(ctx.get(.tools))
        #expect(registry.names.sorted() == ["fetch_url", "web_search"])
        ctx.dispose()
        #expect(service.registeredNames.isEmpty, "上下文释放应撤销 provider 注册")
        #expect(registry.names.isEmpty, "上下文释放应撤销工具注册")
    }

    @Test("抓取后端按凭据选择：配了 FIRECRAWL_API_KEY 走 Firecrawl，否则裸 http")
    @ContextTreeActor
    func fetcherSelection() async throws {
        // 配了 Firecrawl Key：后端应为 FirecrawlFetcher。
        let keyed = Context.root()
        try keyed.provide(.tools, ToolRegistry())
        try provideCredentials(
            keyed, credentials: InMemoryCredentials(initial: ["FIRECRAWL_API_KEY": "f"])
        )
        let withKey = try provideWebTools(keyed, search: SearchService(), session: s20Session())
        let keyedFetcher = try #require(withKey.first { $0.name == "fetch_url" } as? FetchUrlTool)
        #expect(keyedFetcher.backend is FirecrawlFetcher)

        // 显式 fetcher 优先于凭据（另起一个上下文：同名工具不能重复注册）。
        let overrideCtx = Context.root()
        try overrideCtx.provide(.tools, ToolRegistry())
        try provideCredentials(
            overrideCtx, credentials: InMemoryCredentials(initial: ["FIRECRAWL_API_KEY": "f"])
        )
        let explicit = HttpFetcher(session: s20Session())
        let override = try provideWebTools(
            overrideCtx, search: SearchService(), fetcher: explicit, session: s20Session()
        )
        #expect(
            try #require(override.first { $0.name == "fetch_url" } as? FetchUrlTool).backend === explicit
        )

        // 无 Key：裸 http。
        let bare = Context.root()
        try bare.provide(.tools, ToolRegistry())
        let bareTools = try provideWebTools(bare, search: SearchService(), session: s20Session())
        let bareFetcher = try #require(bareTools.first { $0.name == "fetch_url" } as? FetchUrlTool)
        #expect(bareFetcher.backend is HttpFetcher)
        keyed.dispose()
        overrideCtx.dispose()
        bare.dispose()
    }

    @Test("web_search 的 limit 缺省取 defaultLimit；显式 provider 名未注册时透出消息")
    @ContextTreeActor
    func searchToolLimits() async throws {
        let service = SearchService()
        let provider = S20CountingProvider(name: "counting")
        service.register(provider)
        let tool = WebSearchTool(search: service, defaultLimit: 3)
        let result = try await tool.call(
            ToolContext(ToolCall(name: "web_search", callId: "c1", arguments: ["query": .string("q")]))
        )
        #expect(!result.failed)
        #expect(provider.limits == [3], "缺省 limit 走 defaultLimit")

        let result2 = try await tool.call(
            ToolContext(ToolCall(
                name: "web_search", callId: "c2",
                arguments: ["query": .string("q"), "limit": .int(7)]
            ))
        )
        #expect(!result2.failed)
        #expect(provider.limits == [3, 7])

        // 未注册 provider：服务抛错 → 工具转成失败结果。
        let failing = WebSearchTool(search: SearchService())
        let failure = try await failing.call(
            ToolContext(ToolCall(name: "web_search", callId: "c3", arguments: ["query": .string("q")]))
        )
        #expect(failure.failed)
        #expect(failure.error?.code == "SEARCH_UNAVAILABLE")
        #expect(failure.content.hasPrefix("无法联网：所有搜索源都不可用。"))
    }

    @Test("DuckDuckGo 解析器：uddg 解码、跨行属性、空项跳过")
    func duckDuckGoParser() {
        let html = """
        <a rel="nofollow" class="result__a"
           href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=x">跨行 <b>标题</b></a>
        <a class="result__snippet">摘要 &amp; 一</a>
        <a class="result__a" href="">无链接</a>
        <a class="result__a" href="https://example.org/b">没有摘要锚点</a>
        """
        let results = DuckDuckGoHtml.parse(html, limit: 5)
        #expect(results.count == 2, "空链接那条要跳过")
        #expect(results[0].title == "跨行 标题")
        #expect(results[0].url == "https://example.com/a")
        #expect(results[0].snippet == "摘要 & 一")
        #expect(results[1].url == "https://example.org/b")
        #expect(results[1].snippet == "", "摘要锚点越界 → 空串")
        #expect(DuckDuckGoHtml.parse("<html></html>").isEmpty)
        #expect(DuckDuckGoHtml.parse(html, limit: 1).count == 1)
    }
}

/// 记录每次调用 limit 的 provider。
@ContextTreeActor
final class S20CountingProvider: SearchProvider {
    let name: String
    private(set) var limits: [Int] = []

    init(name: String) {
        self.name = name
    }

    func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        limits.append(limit)
        return [SearchResult(title: "T", url: "https://e.test", snippet: "")]
    }
}
