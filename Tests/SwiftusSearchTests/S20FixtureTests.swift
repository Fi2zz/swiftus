import Foundation
import SwiftusCore
import SwiftusCredentials
import SwiftusFoundation
import SwiftusSearch
import Testing

/// 规格 S20 golden fixtures：服务回退（search-service）、源装配（search-registry）、
/// 标记清洗与 HTML 解析（search-markup）、四个 provider 的协议（search-providers）、
/// 两个抓取后端（search-fetch）、两个 web 工具（search-web-tools）。
@Suite("S20 golden fixtures")
struct S20FixtureTests {

    // MARK: search-service · 回退链

    @Test("search-service", arguments: S20FixtureLoader.names(kind: "search-service"))
    @ContextTreeActor
    func searchService(_ name: String) async throws {
        let fixture = try #require(S20FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = S20AssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let input = caseItem["input"]?.objectValue ?? [:]
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let providers = input["providers"]?.arrayValue ?? []

            switch scenario {
            case "registry":
                let service = s20Service(providers)
                var actual: [String: JSONValue] = [
                    "names": .array(service.registeredNames.map { .string($0) }),
                    "foundA": .bool(service.get("a") != nil),
                    "foundMissing": .bool(service.get("nope") != nil),
                ]
                let revocable = s20Service(providers)
                let off = revocable.register(ScriptedProvider(["name": .string("c")]))
                try off()
                try off()
                actual["afterOff"] = .array(revocable.registeredNames.map { .string($0) })
                counter.hit()
                s20ExpectSame(actual, expect, "registry", counter: counter)

            case "fallback":
                let emptyThenHit = input["emptyThenHit"]?.arrayValue ?? []
                let allFail = input["allFail"]?.arrayValue ?? []
                let service = s20Service(providers)
                var actual: [String: JSONValue] = [:]
                actual["firstSuccess"] = s20Results(try await service.search("q"))
                actual["emptyIsSuccess"] = s20Results(
                    try await s20Service(emptyThenHit).search("q")
                )
                actual["emptySkipsNext"] = .array(
                    s20Service(emptyThenHit).registeredNames.map { .string($0) }
                )
                actual["allFailed"] = await s20Guard {
                    s20Results(try await s20Service(allFail).search("q"))
                }
                actual["explicitProvider"] = s20Results(try await service.search("q", provider: "b"))
                actual["explicitFailing"] = await s20Guard {
                    s20Results(try await service.search("q", provider: "a"))
                }
                actual["unregistered"] = await s20Guard {
                    s20Results(try await service.search("q", provider: "z"))
                }
                actual["noProvider"] = await s20Guard {
                    s20Results(try await SearchService().search("q"))
                }
                counter.hit()
                s20ExpectSame(actual, expect, "fallback", counter: counter)

            default:
                Issue.record("未知 scenario：\(scenario)")
            }
        }
        #expect(counter.total > 0, "\(name) 没有产生任何比对")
    }

    // MARK: search-registry · 源装配

    @Test("search-registry", arguments: S20FixtureLoader.names(kind: "search-registry"))
    @ContextTreeActor
    func searchRegistry(_ name: String) async throws {
        let fixture = try #require(S20FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = S20AssertionCounter()
        let session = s20Session()

        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let input = caseItem["input"]?.objectValue ?? [:]
            let expect = caseItem["expect"]?.objectValue ?? [:]

            switch scenario {
            case "table":
                let table = kSearchProviderSpecs
                let actual: [String: JSONValue] = [
                    "names": .array(table.keys.sorted().map { .string($0) }),
                    "credentialKeys": .object(
                        Dictionary(uniqueKeysWithValues: table.keys.sorted().map { key in
                            (key, .string(table[key]?.credentialKey ?? ""))
                        })
                    ),
                    "defaultOrder": .array(kDefaultSearchOrder.map { .string($0) }),
                ]
                counter.hit()
                s20ExpectSame(actual, expect, "table", counter: counter)

            case "build":
                let credentials = input["credentials"]?.objectValue ?? [:]
                let orders = input["orders"]?.objectValue ?? [:]
                func creds(_ key: String) -> InMemoryCredentials {
                    InMemoryCredentials(initial: credentials[key]?.objectValue?.compactMapValues { $0.stringValue } ?? [:])
                }
                var actual: [String: JSONValue] = [:]
                for (slot, orderKey) in [
                    ("missing", "missing"), ("reordered", "reordered"),
                    ("unknown", "unknown"), ("keyless", "keyless"),
                ] {
                    let order = orders[orderKey]?.arrayValue?.compactMap(\.stringValue) ?? []
                    let set = buildSearchProviders(order: order, credentials: creds(slot), session: session)
                    actual["\(slot)Providers"] = .array(set.names.map { .string($0) })
                    actual["\(slot)Statuses"] = .array(set.statuses.map { .object($0.json) })
                }
                counter.hit()
                s20ExpectSame(actual, expect, "build", counter: counter)

            case "assemble":
                // 无凭据服务：只装配免 Key 源。
                let noCreds = Context.root()
                let keylessService = try provideSearch(noCreds, session: session)
                var actual: [String: JSONValue] = [
                    "noCredentials": .object([
                        "providers": .array(keylessService.registeredNames.map { .string($0) }),
                        "statuses": .array(keylessService.statuses.map { .object($0.json) }),
                    ]),
                ]
                noCreds.dispose()
                actual["afterDispose"] = .object([
                    "providers": .int(Int64(keylessService.registeredNames.count)),
                ])

                // 显式凭据。
                let explicit = Context.root()
                let explicitService = try provideSearch(
                    explicit,
                    credentials: InMemoryCredentials(
                        initial: input["explicit"]?.objectValue?.compactMapValues { $0.stringValue } ?? [:]
                    ),
                    session: session
                )
                actual["explicit"] = .object([
                    "providers": .array(explicitService.registeredNames.map { .string($0) }),
                    "statuses": .array(explicitService.statuses.map { .object($0.json) }),
                ])
                explicit.dispose()

                // 缺省凭据取上下文服务。
                let fromCtx = Context.root()
                try provideCredentials(
                    fromCtx,
                    credentials: InMemoryCredentials(
                        initial: input["fromContext"]?.objectValue?.compactMapValues { $0.stringValue } ?? [:]
                    )
                )
                let ctxService = try provideSearch(fromCtx, session: session)
                actual["fromContext"] = .object([
                    "providers": .array(ctxService.registeredNames.map { .string($0) }),
                ])
                fromCtx.dispose()

                // 显式 providers 忽略 order，statuses 为空。
                let scripted = Context.root()
                let scriptedService = try provideSearch(
                    scripted,
                    order: ["tavily"],
                    credentials: InMemoryCredentials(
                        initial: ["TAVILY_API_KEY": "t"]
                    ),
                    providers: [ScriptedProvider(["name": .string("x")])],
                    session: session
                )
                actual["explicitProviders"] = .object([
                    "providers": .array(scriptedService.registeredNames.map { .string($0) }),
                    "statuses": .int(Int64(scriptedService.statuses.count)),
                ])
                scripted.dispose()

                counter.hit()
                s20ExpectSame(actual, expect, "assemble", counter: counter)

            default:
                Issue.record("未知 scenario：\(scenario)")
            }
        }
        #expect(counter.total > 0, "\(name) 没有产生任何比对")
    }

    // MARK: search-markup · 清洗与解析

    @Test("search-markup", arguments: S20FixtureLoader.names(kind: "search-markup"))
    @ContextTreeActor
    func searchMarkup(_ name: String) async throws {
        let fixture = try #require(S20FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = S20AssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let inputs = caseItem["input"]?.arrayValue ?? []
            let expects = caseItem["expect"]?.arrayValue ?? []
            for (input, expect) in zip(inputs, expects) {
                let text = input.objectValue?["input"]?.stringValue ?? ""
                // 清洗用例的 expect 与 input 同形（{input, expect}），这里取其中的期望值。
                let want = expect.objectValue?["expect"] ?? .null
                let actual: JSONValue
                switch scenario {
                case "strip-markup": actual = .string(SearchMarkup.strip(text))
                case "strip-html": actual = .string(SearchMarkup.stripHTML(text))
                default:
                    Issue.record("未知 scenario：\(scenario)")
                    continue
                }
                counter.hit()
                #expect(actual == want, "「\(scenario)」\(text) 清洗结果不一致")
            }
            if scenario == "duckduckgo-parse" {
                let cases = caseItem["input"]?["cases"]?.arrayValue ?? []
                for (input, expect) in zip(cases, expects) {
                    let html = input.objectValue?["html"]?.stringValue ?? ""
                    let limit = Int(input.objectValue?["limit"]?.intValue ?? 5)
                    let results = DuckDuckGoHtml.parse(html, limit: limit)
                    counter.hit()
                    s20ExpectSame(
                        s20Results(results).objectValue ?? [:],
                        expect.objectValue ?? [:],
                        "ddg \(html.prefix(24))",
                        counter: counter
                    )
                }
            }
        }
        #expect(counter.total > 0, "\(name) 没有产生任何比对")
    }

    /// **URL 桩相关的三个 kind 走这一条用例，按序执行。**
    ///
    /// 不能拆成三条 `@Test`：桩注册表是进程级单例，而 swift-testing 并发跑用例；
    /// 用 `NSLock` 串行会在**协作线程池**上死锁（持锁线程被占满 → URLSession 的
    /// 回调拿不到线程 → 全部挂起，本项目在这挂过一次）。端点又必须与 fixture 逐字
    /// 一致（`host` / `path` / 回显的 `url` 都在投影里），没法靠换主机隔离，故只能串。
    @Test("search-providers / search-fetch / search-web-tools（URL 桩，串行）")
    @ContextTreeActor
    func urlStubKindsSequentially() async throws {
        try await searchProviders("search-providers")
        try await searchFetch("search-fetch")
        try await searchWebTools("search-web-tools")
    }

    // MARK: search-providers · 协议

    /// `search-providers` 的 fixture 驱动（**不是**独立 @Test，见下方串行闸的说明）。
    @ContextTreeActor
    func searchProviders(_ name: String) async throws {
        let fixture = try #require(S20FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = S20AssertionCounter()
        let session = s20Session()

        S20StubProtocol.registry.reset()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let input = caseItem["input"]?.objectValue ?? [:]
            let expect = caseItem["expect"]?.objectValue ?? [:]
            // 四个 provider 挂在同一 host+path 上，桩队列按 case 重置（整体已串行）。
            S20StubProtocol.registry.reset()
            let endpoint = input["endpoint"]?.stringValue ?? "https://probe.test/search"
            let query = input["query"]?.stringValue ?? "q"
            let limit = Int(input["limit"]?.intValue ?? 5)
            let apiKey = input["apiKey"]?.stringValue ?? "k"
            // 端点带一个用例内唯一的路径后缀，避免并发用例共用同一 authority 分桶。
            let unique = endpoint

            var actual: [String: JSONValue] = [:]
            switch scenario {
            case "tavily":
                let responses = (input["responses"]?.arrayValue ?? []).enumerated().map { index, item in
                    item.objectValue ?? [:]
                }
                s20Stub(s20At(responses, 0) ?? [:], endpoint: unique)
                let provider = TavilySearchProvider(apiKey: apiKey, session: session, endpoint: unique)
                actual["name"] = .string(provider.name)
                actual["results"] = s20Results(try await provider.search(query, limit: limit))
                actual["shape"] = S20StubProtocol.registry.shape(of: unique)
                s20Stub(s20At(responses, 1) ?? [:], endpoint: unique)
                actual["httpError"] = await s20Guard {
                    s20Results(try await TavilySearchProvider(
                        apiKey: apiKey, session: session, endpoint: unique
                    ).search("q"))
                }
                s20Stub(s20At(responses, 2) ?? [:], endpoint: unique)
                actual["badJson"] = await s20Guard {
                    s20Results(try await TavilySearchProvider(
                        apiKey: apiKey, session: session, endpoint: unique
                    ).search("q"))
                }

            case "exa":
                s20Stub(input["response"]?.objectValue ?? [:], endpoint: unique)
                let provider = ExaSearchProvider(apiKey: apiKey, session: session, endpoint: unique)
                actual["name"] = .string(provider.name)
                actual["results"] = s20Results(try await provider.search(query, limit: limit))
                actual["shape"] = S20StubProtocol.registry.shape(of: unique)

            case "brave":
                s20Stub(input["response"]?.objectValue ?? [:], endpoint: unique)
                let provider = BraveSearchProvider(apiKey: apiKey, session: session, endpoint: unique)
                actual["name"] = .string(provider.name)
                actual["results"] = s20Results(try await provider.search(query, limit: limit))
                actual["shape"] = S20StubProtocol.registry.shape(of: unique)
                s20Stub(input["noWebKeyResponse"]?.objectValue ?? [:], endpoint: unique)
                actual["noWebKey"] = s20Results(
                    try await BraveSearchProvider(apiKey: apiKey, session: session, endpoint: unique).search("q")
                )

            case "duckduckgo":
                s20Stub(input["response"]?.objectValue ?? [:], endpoint: unique)
                let provider = DuckDuckGoSearchProvider(session: session, endpoint: unique)
                actual["name"] = .string(provider.name)
                actual["results"] = s20Results(try await provider.search(query, limit: limit))
                actual["shape"] = S20StubProtocol.registry.shape(of: unique)
                s20Stub(input["errorResponse"]?.objectValue ?? [:], endpoint: unique)
                actual["httpError"] = await s20Guard {
                    s20Results(try await DuckDuckGoSearchProvider(
                        session: session, endpoint: unique
                    ).search("q"))
                }

            default:
                Issue.record("未知 scenario：\(scenario)")
                continue
            }
            counter.hit()
            s20ExpectSame(actual, expect, scenario, counter: counter)
        }
        #expect(counter.total > 0, "\(name) 没有产生任何比对")
    }

    // MARK: search-fetch · 抓取

    /// `search-fetch` 的 fixture 驱动（**不是**独立 @Test，见下方串行闸的说明）。
    @ContextTreeActor
    func searchFetch(_ name: String) async throws {
        let fixture = try #require(S20FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = S20AssertionCounter()
        let session = s20Session()

        S20StubProtocol.registry.reset()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let input = caseItem["input"]?.objectValue ?? [:]
            let expect = caseItem["expect"]?.objectValue ?? [:]
            S20StubProtocol.registry.reset()
            let page = input["page"]?.stringValue ?? "https://example.com/post"
            let maxChars = Int(input["maxChars"]?.intValue ?? 20000)
            let endpoint = input["endpoint"]?.stringValue ?? "https://probe.test/scrape"
            let unique = endpoint

            var actual: [String: JSONValue] = [:]
            switch scenario {
            case "http":
                // 同一端点要连打多次（ok、truncated），桩按队列消费。
                s20Stub(input["response"]?.objectValue ?? [:], endpoint: page, times: 2)
                let fetcher = HttpFetcher(session: session)
                let fetched = try await fetcher.fetch(page, maxChars: 20000)
                actual["ok"] = .object([
                    "page": .object([
                        "url": .string(fetched.url),
                        "content": .string(fetched.content),
                        "format": .string(fetched.format.rawValue),
                    ]),
                    "shape": S20StubProtocol.registry.shape(of: page),
                    "truncated": .string(try await fetcher.fetch(page, maxChars: maxChars).content),
                ])
                actual["errors"] = .object(await s20ErrorProjections(
                    input["errors"]?.objectValue ?? [:]
                ) { spec in
                    // 链接校验类：spec 本身就是链接串（`not a url` / `https://`）。
                    if case .string(let url) = spec { return await s20FetchContent(fetcher, url) }
                    // 状态码 / 传输失败类：桩挂在本用例的端点上，抓 page。
                    s20Stub(spec.objectValue ?? [:], endpoint: page)
                    return await s20FetchContent(fetcher, page)
                })

            case "firecrawl":
                s20Stub(input["response"]?.objectValue ?? [:], endpoint: unique, times: 2)
                let fetcher = FirecrawlFetcher(
                    apiKey: input["apiKey"]?.stringValue ?? "f", session: session, endpoint: unique
                )
                let fetched = try await fetcher.fetch(page, maxChars: 20000)
                actual["ok"] = .object([
                    "page": .object([
                        "url": .string(fetched.url),
                        "content": .string(fetched.content),
                        "format": .string(fetched.format.rawValue),
                    ]),
                    "shape": S20StubProtocol.registry.shape(of: unique),
                    "truncated": .string(try await fetcher.fetch(page, maxChars: maxChars).content),
                ])
                var errorShape = await s20ErrorProjections(
                    input["errors"]?.objectValue ?? [:]
                ) { spec in
                    if case .string(let url) = spec { return await s20FetchContent(fetcher, url) }
                    s20Stub(spec.objectValue ?? [:], endpoint: unique)
                    return await s20FetchContent(fetcher, page)
                }
                errorShape["credentialKey"] = .string(kFirecrawlCredentialKey)
                actual["errors"] = .object(errorShape)
                actual["credentialKey"] = .string(kFirecrawlCredentialKey)

            default:
                Issue.record("未知 scenario：\(scenario)")
                continue
            }
            counter.hit()
            s20ExpectSame(actual, expect, scenario, counter: counter)
        }
        #expect(counter.total > 0, "\(name) 没有产生任何比对")
    }

    // MARK: search-web-tools · 工具

    /// `search-web-tools` 的 fixture 驱动（**不是**独立 @Test，见下方串行闸的说明）。
    @ContextTreeActor
    func searchWebTools(_ name: String) async throws {
        let fixture = try #require(S20FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = S20AssertionCounter()
        let session = s20Session()

        S20StubProtocol.registry.reset()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let input = caseItem["input"]?.objectValue ?? [:]
            let expect = caseItem["expect"]?.objectValue ?? [:]
            var actual: [String: JSONValue] = [:]

            switch scenario {
            case "web-search":
                let query = input["query"]?.stringValue ?? "q"
                let results = input["results"]?.arrayValue ?? []
                let statuses = input["statuses"]?.arrayValue ?? []
                let hit = s20Service(
                    [.object(["name": .string("a"), "results": .array(results)])],
                    statuses: statuses
                )
                let hitResult = try await WebSearchTool(search: hit).call(
                    ToolContext(ToolCall(name: "web_search", callId: "c1", arguments: ["query": .string(query)]))
                )
                actual["hitText"] = .string(hitResult.content)
                actual["hitValue"] = hitResult.value ?? .null
                actual["hitFailed"] = .bool(hitResult.failed)

                let emptyService = s20Service(
                    [.object(["name": .string("a"), "results": .array([])])],
                    statuses: statuses
                )
                let emptyResult = try await WebSearchTool(search: emptyService).call(
                    ToolContext(ToolCall(name: "web_search", callId: "c2", arguments: ["query": .string(query)]))
                )
                actual["emptyText"] = .string(emptyResult.content)
                actual["emptyValue"] = emptyResult.value ?? .null
                actual["emptyFailed"] = .bool(emptyResult.failed)

                let failing = s20Service(
                    [.object(["name": .string("a"), "fails": .bool(true), "error": .string("boom")])],
                    statuses: statuses
                )
                let failed = try await WebSearchTool(search: failing).call(
                    ToolContext(ToolCall(name: "web_search", callId: "c3", arguments: ["query": .string(query)]))
                )
                actual["failedText"] = .string(failed.content)
                actual["failedError"] = failed.error.map { .string($0.code) } ?? .null
                actual["failedMessage"] = failed.error.map { .string($0.message) } ?? .null

            case "fetch-url":
                let page = input["url"]?.stringValue ?? "https://example.com/p"
                let unique = page
                s20Stub(input["response"]?.objectValue ?? [:], endpoint: unique, times: 2)
                let tool = FetchUrlTool(fetcher: HttpFetcher(session: session))
                let ok = try await tool.call(
                    ToolContext(ToolCall(name: "fetch_url", callId: "c4", arguments: ["url": .string(unique)]))
                )
                actual["okText"] = .string(ok.content)
                actual["okValue"] = ok.value ?? .null
                actual["okFailed"] = .bool(ok.failed)

                let invalid = input["invalid"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let badScheme = try await tool.call(
                    ToolContext(ToolCall(
                        name: "fetch_url", callId: "c5",
                        arguments: ["url": .string(invalid.first ?? "ftp://x/y")]
                    ))
                )
                actual["badSchemeText"] = .string(badScheme.content)
                actual["badSchemeCode"] = badScheme.error.map { .string($0.code) } ?? .null
                let unparseable = try await tool.call(
                    ToolContext(ToolCall(
                        name: "fetch_url", callId: "c6",
                        arguments: ["url": .string(invalid.count > 1 ? invalid[1] : "不是链接")]
                    ))
                )
                actual["unparseableText"] = .string(unparseable.content)
                actual["unparseableCode"] = unparseable.error.map { .string($0.code) } ?? .null

                // 失败用的链接由 fixture 指定（该端点上只挂 404 桩）。
                let failingURL = input["failing"]?.objectValue?["url"]?.stringValue
                    ?? "\(page.rstripSlashes())/gone"
                s20Stub(input["failing"]?.objectValue ?? [:], endpoint: failingURL)
                let failedResult = try await tool.call(
                    ToolContext(ToolCall(
                        name: "fetch_url", callId: "c7", arguments: ["url": .string(failingURL)]
                    ))
                )
                actual["failedText"] = .string(failedResult.content)
                actual["failedCode"] = failedResult.error.map { .string($0.code) } ?? .null
                actual["failedMessage"] = failedResult.error.map { .string($0.message) } ?? .null

            default:
                Issue.record("未知 scenario：\(scenario)")
                continue
            }
            counter.hit()
            s20ExpectSame(actual, expect, scenario, counter: counter)
        }
        #expect(counter.total > 0, "\(name) 没有产生任何比对")
    }
}

// MARK: - 辅助

/// 越界取空（fixture 用例表按序读，少一条就少跑一条而不是崩）。
func s20At<T>(_ list: [T], _ index: Int) -> T? {
    list.indices.contains(index) ? list[index] : nil
}

extension String {
    /// 去掉尾部斜杠（拼用例内唯一端点用）。
    func rstripSlashes() -> String {
        var text = self
        while text.last == "/" { text.removeLast() }
        return text
    }
}

/// 深度求首个差异（最多三条）。
func s20ExpectSame(
    _ actual: [String: JSONValue],
    _ expected: [String: JSONValue],
    _ label: String,
    counter: S20AssertionCounter,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    counter.hit()
    guard actual != expected else { return }
    for (path, got, want) in s20Differences(actual: .object(actual), expected: .object(expected)) {
        Issue.record(
            "「\(label)」\(path) 不一致\n  实际：\(s20Brief(got))\n  期望：\(s20Brief(want))",
            sourceLocation: sourceLocation
        )
    }
}

private func s20Differences(
    actual: JSONValue,
    expected: JSONValue,
    path: String = "",
    limit: Int = 3
) -> [(String, JSONValue, JSONValue)] {
    if actual == expected { return [] }
    guard case let .object(got) = actual, case let .object(want) = expected else {
        return [(path.isEmpty ? "(root)" : path, actual, expected)]
    }
    var found: [(String, JSONValue, JSONValue)] = []
    for key in want.keys.sorted() {
        if found.count >= limit { return found }
        let child = path.isEmpty ? key : "\(path).\(key)"
        found += s20Differences(
            actual: got[key] ?? .null, expected: want[key] ?? .null,
            path: child, limit: limit - found.count
        )
    }
    for key in got.keys.sorted() where want[key] == nil {
        if found.count >= limit { return found }
        found.append((path.isEmpty ? key : "\(path).\(key)", got[key] ?? .null, .null))
    }
    return found.isEmpty ? [(path.isEmpty ? "(root)" : path, actual, expected)] : found
}

private func s20Brief(_ value: JSONValue, limit: Int = 200) -> String {
    guard case let .string(text) = value else { return String(describing: value) }
    return text.count > limit ? String(text.prefix(limit)) + "…" : text
}

/// 断言计数：每个 fixture 至少要比对一次。
final class S20AssertionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func hit() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}

/// 装载自检：每个 kind 恰好命中一个 fixture 文件、用例非空、每条用例自带输入。
@Suite("S20 fixtures 装载自检")
struct S20FixtureInventoryTests {
    @Test("s20 各 kind 恰好一件且用例非空", arguments: S20FixtureLoader.kinds)
    func inventory(_ kind: String) {
        let fixtures = S20FixtureLoader.load(kind: kind)
        #expect(fixtures.count == 1, "\(kind) 应恰好命中一个 fixture 文件（实际 \(fixtures.count)）")
        #expect(fixtures.first?.cases.isEmpty == false, "\(kind) 的用例不应为空")
    }

    @Test("s20 每条用例自带输入", arguments: S20FixtureLoader.kinds)
    func selfDescribing(_ kind: String) {
        for fixture in S20FixtureLoader.load(kind: kind) {
            for caseItem in fixture.cases {
                #expect(
                    caseItem["input"] != nil,
                    "\(fixture.name)/\(caseItem["scenario"]?.stringValue ?? "?") 缺 input"
                )
            }
        }
    }
}

// MARK: - 抓取错误投影

/// 抓一次并把正文包成 `{content: …}`（成功）或 `{error: …}` / `{errorPrefix: …}`（失败）。
@ContextTreeActor
func s20FetchContent(_ fetcher: any WebFetcher, _ url: String) async -> JSONValue {
    do {
        return .object(["content": .string(try await fetcher.fetch(url, maxChars: 20_000).content)])
    } catch let error as FetchException {
        // 传输层失败的原因文本是语言相关的运行时描述 → 只投影前缀。
        if error.message.hasPrefix("抓取失败：") {
            return .object(["errorPrefix": .string("抓取失败：")])
        }
        return .object(["error": .string(error.message)])
    } catch {
        return .object(["error": .string(String(describing: type(of: error)))])
    }
}

/// 把 fixture 的 `errors` 表跑成投影。
///
/// 每条 spec 四种形态：`"<链接>"`（字符串，链接校验类）、`{url}`、`{status, body}`
/// （挂桩抓 page，状态码 / 响应体类）、`{networkError}`（挂传输失败桩，只比前缀）。
@ContextTreeActor
func s20ErrorProjections(
    _ errors: [String: JSONValue],
    _ run: ((JSONValue) async -> JSONValue)
) async -> [String: JSONValue] {
    var projected: [String: JSONValue] = [:]
    for (key, spec) in errors.sorted(by: { $0.key < $1.key }) {
        projected[key] = await run(spec)
    }
    return projected
}
