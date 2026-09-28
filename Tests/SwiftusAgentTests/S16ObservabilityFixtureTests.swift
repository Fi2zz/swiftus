import Foundation
import SwiftusAgent
import SwiftusCompaction
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM
import Testing

/// 规格 S16 §5 golden fixtures：telemetry-flow / caching / layered-compaction / eval。
/// ms / durationMs 为墙钟度量，断言「存在且非负」不比具体值。
@Suite("S16 观测与缓存 fixtures")
struct S16ObservabilityFixtureTests {
    private static let fixtures = S16FixtureLoader.loadAllOrEmpty()

    @Test("telemetry-flow", arguments: Self.fixtures.filter { $0.kind == "telemetry-flow" })
    @ContextTreeActor
    func telemetryFlow(_ fixture: S16Fixture) async throws {
        let expected = fixture.raw["expect"]?.objectValue?["events"]?.arrayValue ?? []
        let ctx = Context.root()
        defer { ctx.dispose() }
        let telemetry = try InMemoryTelemetry()
        try provideTelemetry(ctx, telemetry: telemetry)
        let registry = ToolRegistry()
        _ = try registry.register(GetTimeTool())
        try ctx.provide(.tools, registry)
        try instrumentTools(ctx)
        let scripted = ScriptedProvider([
            scriptedCall("c1", "get_time"),
            scriptedText("12:00"),
        ])
        var config = AgentLoop.Config()
        config.onEvent = { type, data in telemetry.emit(TelemetryEvent(type, data: data)) }
        let loop = AgentLoop(
            llm: TelemetryLlmProvider(scripted, telemetry: telemetry),
            tools: registry,
            config: config
        )
        try await loop.run("现在几点")
        let actual = telemetry.recent.map { event in
            JSONValue.object([
                "name": .string(event.name),
                "data": .object(event.data.filter { $0.key != "ms" }),
            ])
        }
        let expectedStripped = expected.map { entry -> JSONValue in
            guard var object = entry.objectValue else { return entry }
            var data = object["data"]?.objectValue ?? [:]
            data.removeValue(forKey: "ms")
            object["data"] = .object(data)
            return .object(object)
        }
        #expect(actual == expectedStripped)
        for event in telemetry.recent where event.data.keys.contains("ms") {
            #expect(event.data["ms"]?.intValue ?? -1 >= 0)
        }
    }

    @Test("caching", arguments: Self.fixtures.filter { $0.kind == "caching" })
    @ContextTreeActor
    func caching(_ fixture: S16Fixture) async throws {
        try checkCachePlans(fixture)
        try checkCacheHits(fixture)
        try await checkCachePassthrough(fixture)
    }

    @Test("layered-compaction", arguments: Self.fixtures.filter { $0.kind == "layered-compaction" })
    @ContextTreeActor
    func layeredCompaction(_ fixture: S16Fixture) async throws {
        let expect = fixture.raw["expect"]?.objectValue ?? [:]
        let session = try Session(id: "s1")
        try session.append(SessionEventKind.userMessage, data: .object(["text": .string("记住我喜欢清淡饮食")]))
        for index in 0..<6 {
            try session.append(SessionEventKind.userMessage, data: .object(["text": .string("早期闲聊第\(index)条")]))
        }
        try session.append(SessionEventKind.assistantMessage, data: .object([
            "text": .string(""),
            "toolCalls": .array([.object(["id": .string("c1"), "name": .string("search"), "arguments": .string("{}")])]),
        ]))
        try session.append(SessionEventKind.toolResult, data: .object([
            "callId": .string("c1"),
            "name": .string("search"),
            "content": .string("很长的搜索结果正文第一行\n其余部分省略"),
        ]))
        try session.append(SessionEventKind.userMessage, data: .object(["text": .string("今天吃什么")]))
        let compactor = try LayeredCompactor(
            keepRecent: 1,
            classifier: RuleBasedContentClassifier(recentWindow: 2)
        )
        let result = try await compactor.compactIfNeeded(session) { events, _ in
            CompactionSummary(events.isEmpty ? "（无早期对话）" : "早期对话要点", provider: "scripted", model: "m")
        }
        #expect(result?.summary == expect["summary"]?.stringValue)
        #expect(result?.shadowedSeqs == (expect["shadowedSeqs"]?.arrayValue?.compactMap(\.intValue) ?? []))
        #expect(result?.kept == expect["kept"]?.intValue)
        #expect(checkCompactionInvariant(session.events).isEmpty)
    }

    @Test("eval", arguments: Self.fixtures.filter { $0.kind == "eval" })
    @ContextTreeActor
    func eval(_ fixture: S16Fixture) async throws {
        let caseA = EvalCase(
            id: "a",
            input: "现在几点",
            expectedTools: ["get_time"],
            expectedOutput: "12:00",
            maxRounds: 2
        )
        let passResult = EvalResult(
            caseId: "a", passed: false, actualTools: ["get_time"],
            actualOutput: "12:00", rounds: 1, duration: 0
        )
        let failResult = EvalResult(
            caseId: "a", passed: false, actualTools: [],
            actualOutput: "不知道", rounds: 3, duration: 0
        )
        let judgeCases = fixture.raw["judgeCases"]?.arrayValue ?? []
        #expect(defaultEvalJudge(caseA, passResult) == (judgeCases[0]["expect"] == .bool(true)))
        #expect(defaultEvalJudge(caseA, failResult) == (judgeCases[1]["expect"] == .bool(true)))

        let expect = fixture.raw["expect"]?.objectValue ?? [:]
        let scripted = ScriptedProvider([scriptedCall("c1", "get_time"), scriptedText("12:00")])
        let registry = ToolRegistry()
        _ = try registry.register(GetTimeTool())
        let loop = AgentLoop(llm: scripted, tools: registry)
        let evaluator = Evaluator(run: { input in try await loop.run(input) })
        let report = try await evaluator.runAll([
            caseA,
            EvalCase(id: "b", input: "你好", expectedOutput: "12:00"),
        ])
        #expect(report.passedCount == expect["passedCount"]?.intValue)
        #expect(report.passRate == doubleOf(expect["passRate"]))
        #expect(report.averageRounds == doubleOf(expect["averageRounds"]))
        let expectedResults = expect["results"]?.arrayValue ?? []
        #expect(report.results.count == expectedResults.count)
        for (actual, expected) in zip(report.results, expectedResults) {
            let object = expected.objectValue ?? [:]
            #expect(actual.caseId == object["caseId"]?.stringValue)
            #expect(actual.passed == (object["passed"] == .bool(true)))
            #expect(actual.actualTools == (object["actualTools"]?.arrayValue?.compactMap(\.stringValue) ?? []))
            #expect(actual.actualOutput == object["actualOutput"]?.stringValue)
            #expect(actual.rounds == object["rounds"]?.intValue)
        }
        let baseline = EvalReport([
            EvalResult(caseId: "a", passed: true, actualTools: ["get_time"], actualOutput: "12:00", rounds: 1, duration: 0),
        ])
        #expect(report.compareTo(baseline).description == expect["diffText"]?.stringValue)
    }

    // ─── caching 分段 ───

    @ContextTreeActor
    private func checkCachePlans(_ fixture: S16Fixture) throws {
        let cases = fixture.raw["planCases"]?.arrayValue ?? []
        var cacheable = LlmMessage("system", "稳定前缀")
        cacheable.cacheable = true
        var cacheableAgain = LlmMessage("system", "不再计入")
        cacheableAgain.cacheable = true
        let truncated = CachePlan.of([cacheable, LlmMessage("user", "不可缓存"), cacheableAgain])
        let truncatedExpect = cases[0]["expect"]?.objectValue ?? [:]
        #expect(truncated.cacheableMessages == truncatedExpect["cacheableMessages"]?.intValue)
        #expect(truncated.cacheableChars == truncatedExpect["cacheableChars"]?.intValue)
        #expect(truncated.empty == (truncatedExpect["empty"] == .bool(true)))

        var prefixA = LlmMessage("system", "前缀A")
        prefixA.cacheable = true
        var prefixB = LlmMessage("system", "前缀B")
        prefixB.cacheable = true
        let sameKey = CachePlan.of([prefixA]).cacheKey == CachePlan.of([prefixA]).cacheKey
        let diffKey = CachePlan.of([prefixA]).cacheKey == CachePlan.of([prefixB]).cacheKey
        #expect(sameKey == (cases[1]["expect"]?.objectValue?["same"] == .bool(true)))
        #expect(diffKey == (cases[2]["expect"]?.objectValue?["same"] == .bool(true)))
    }

    @ContextTreeActor
    private func checkCacheHits(_ fixture: S16Fixture) throws {
        for caseItem in fixture.raw["hitCases"]?.arrayValue ?? [] {
            let usage = caseItem["usage"]?.objectValue ?? [:]
            let cache = ContextCache()
            cache.recordHit(plan: CachePlan.of([]), usage: usage)
            let expected = caseItem["expect"]?.objectValue?["hit"] == .bool(true)
            #expect((cache.hits == 1) == expected)
        }
    }

    @ContextTreeActor
    private func checkCachePassthrough(_ fixture: S16Fixture) async throws {        let usage = fixture.raw["passthrough"]?.objectValue?["usage"]?.objectValue ?? [:]
        var scripted = scriptedText("好")
        scripted.usage = usage
        let provider = ScriptedProvider([scripted])
        let cache = ContextCache()
        let decorated = CachingLlmProvider(provider, cache: cache)
        var system = LlmMessage("system", "前缀")
        system.cacheable = true
        let result = try await decorated.chat(LlmRequest(messages: [system]))
        #expect(result.content == "好")
        #expect(cache.hits == 1 && cache.misses == 0)
        #expect(provider.calls.count == 1)
        #expect(provider.calls.first?.first?.cacheable == true)
    }
}

/// JSONValue 的数值读取（int / double 双形态统一为 Double）。
private func doubleOf(_ value: JSONValue?) -> Double? {
    if case let .double(number) = value { return number }
    if case let .int(number) = value { return Double(number) }
    return nil
}
