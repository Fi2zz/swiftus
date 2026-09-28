import Foundation
import SwiftusAgent
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM
import Testing

/// 规格 S16 golden fixtures：plan / reflection / router-flow / planning-phase。
@Suite("S16 golden fixtures")
struct S16FixtureTests {
    private static let fixtures = S16FixtureLoader.loadAllOrEmpty()

    @Test("fixtures 已装载（spec/fixtures/s16/*.json）")
    func fixturesLoaded() {
        #expect(Self.fixtures.count >= 4)
    }

    @Test("plan", arguments: Self.fixtures.filter { $0.kind == "plan" })
    @ContextTreeActor
    func plan(_ fixture: S16Fixture) async throws {
        let session = try Session(id: "s1")
        let registry = ToolRegistry()
        _ = try registry.register(PlanTool(session: session))
        let first = await registry.call(ToolCall(name: kPlanToolName, arguments: [
            "goal": .string("写一份报告"),
            "steps": .array([.string("收集资料"), .string(""), .string("  撰写  "), .string("校对")]),
        ]))
        let writeRead = fixture.cases[0]["expect"]?.objectValue ?? [:]
        #expect(first.content == writeRead["content"]?.stringValue)
        #expect(first.value == writeRead["value"])
        #expect(readPlan(session)?.jsonValue == writeRead["plan"])
        #expect(planSection(session) == writeRead["section"]?.stringValue)
        #expect(session.events.last?.type == writeRead["eventType"]?.stringValue)

        _ = await registry.call(ToolCall(name: kPlanToolName, arguments: ["goal": .string("新目标")]))
        #expect(readPlan(session)?.goal == fixture.cases[1]["expect"]?.objectValue?["goal"]?.stringValue)

        let empty = try Session(id: "s2")
        #expect(planSection(empty) == (fixture.cases[2]["expect"]?.objectValue?["section"]?.stringValue ?? ""))
    }

    @Test("reflection", arguments: Self.fixtures.filter { $0.kind == "reflection" })
    @ContextTreeActor
    func reflection(_ fixture: S16Fixture) async throws {
        try checkDecisionCases(fixture)
        checkShouldReflectCases(fixture)
        try await checkRetryCase(fixture)
        try await checkReplanCase(fixture)
    }

    @Test("router-flow", arguments: Self.fixtures.filter { $0.kind == "router-flow" })
    @ContextTreeActor
    func routerFlow(_ fixture: S16Fixture) async throws {
        for caseItem in fixture.cases {
            try await checkRouterCase(caseItem)
        }
    }

    @Test("planning-phase", arguments: Self.fixtures.filter { $0.kind == "planning-phase" })
    @ContextTreeActor
    func planningPhase(_ fixture: S16Fixture) async throws {
        try await checkPlanningPhase(fixture)
        try await checkPlanningSkipped(fixture)
    }

    // ─── reflection 分段 ───

    @ContextTreeActor
    private func checkDecisionCases(_ fixture: S16Fixture) throws {
        for caseItem in fixture.raw["decisionCases"]?.arrayValue ?? [] {
            let input = caseItem["input"]?.stringValue ?? ""
            let expected = caseItem["expect"]?.stringValue ?? ""
            #expect(ReflectionDecision.parse(input).action.rawValue == expected)
        }
    }

    @ContextTreeActor
    private func checkShouldReflectCases(_ fixture: S16Fixture) {
        for caseItem in fixture.raw["shouldReflectCases"]?.arrayValue ?? [] {
            let object = caseItem.objectValue ?? [:]
            let strategy = ReflectionStrategy(rawValue: object["strategy"]?.stringValue ?? "") ?? .never
            let reflector = Reflector(llm: ScriptedProvider([]), strategy: strategy)
            let tool = object["risk"]?.stringValue == "medium" ? ProbeTool(risk: .medium) : ProbeTool(risk: .low)
            let result: ToolResult = object["failed"] == .bool(true)
                ? .failure("坏", error: ToolError("X", "bad"))
                : .success("好")
            let expected = object["expect"] == .bool(true)
            #expect(reflector.shouldReflect(tool, result) == expected)
        }
    }

    @ContextTreeActor
    private func checkRetryCase(_ fixture: S16Fixture) async throws {
        let expect = fixture.raw["retryCase"]?.objectValue?["expect"]?.objectValue ?? [:]
        let llm = ScriptedProvider([scriptedText(#"{"decision":"retry"}"#), scriptedText(#"{"decision":"continue"}"#)])
        let reflector = Reflector(llm: llm, strategy: .always, maxRetries: 1)
        let registry = ToolRegistry()
        _ = try registry.register(ProbeTool(risk: .low))
        let counter = InvokeCounter()
        let outcome = try await reflectAndRetry(
            reflector,
            call: LlmToolCall(id: "c1", name: "probe"),
            initial: .failure("bad", error: ToolError("X", "bad")),
            context: ReflectionContext(
                tools: registry,
                task: "任务",
                plan: nil,
                invoke: { _ in
                    counter.increment()
                    return .success("ok")
                }
            )
        )
        #expect(counter.count == expect["invocations"]?.intValue)
        #expect(outcome.content == expect["content"]?.stringValue)
        #expect(llm.calls.count == expect["reflectCalls"]?.intValue)
    }

    @ContextTreeActor
    private func checkReplanCase(_ fixture: S16Fixture) async throws {
        let expect = fixture.raw["replanCase"]?.objectValue?["expect"]?.objectValue ?? [:]
        let llm = ScriptedProvider([scriptedText(#"{"decision":"replan"}"#)])
        let reflector = Reflector(llm: llm, strategy: .always)
        let registry = ToolRegistry()
        _ = try registry.register(ProbeTool(risk: .low))
        let counter = InvokeCounter()
        var replanned = false
        let outcome = try await reflectAndRetry(
            reflector,
            call: LlmToolCall(id: "c1", name: "probe"),
            initial: .failure("bad", error: ToolError("X", "bad")),
            context: ReflectionContext(
                tools: registry,
                task: "任务",
                plan: nil,
                invoke: { _ in
                    counter.increment()
                    return .success("ok")
                },
                onReplan: { replanned = true }
            )
        )
        #expect(counter.count == expect["invocations"]?.intValue)
        #expect(replanned == (expect["replanned"] == .bool(true)))
        #expect(outcome.content == expect["content"]?.stringValue)
    }

    // ─── router-flow 分段 ───

    @ContextTreeActor
    private func checkRouterCase(_ caseItem: JSONValue) async throws {
        let label = caseItem["label"]?.stringValue ?? ""
        let expect = caseItem["expect"]?.objectValue ?? [:]
        let llm = ScriptedProvider(routerScript(label))
        let registry = ToolRegistry()
        _ = try registry.register(GetTimeTool())
        var config = AgentLoop.Config()
        config.router = fixtureRouter(label)
        let loop = AgentLoop(llm: llm, tools: registry, config: config)
        let turn = try await loop.run("现在几点")
        #expect(turn.reply == expect["reply"]?.stringValue, "\(label) reply")
        #expect(llm.calls.count == expect["modelCalls"]?.intValue, "\(label) modelCalls")
        if let roles = expect["lastRoles"]?.arrayValue {
            #expect(llm.calls.first?.map(\.role) == roles.compactMap(\.stringValue), "\(label) roles")
            #expect(llm.calls.first?.last?.content == expect["toolContent"]?.stringValue, "\(label) toolContent")
        }
    }

    /// 每个用例独立脚本（与导出器对齐）：reply 用例不该调模型，tools 用例收口
    /// 「现在是 12:00」，pass 用例「模型回答」。
    private func routerScript(_ label: String) -> [LlmResult] {
        if label.contains("tools") {
            return [scriptedText("现在是 12:00")]
        }
        if label.contains("pass") {
            return [scriptedText("模型回答")]
        }
        return [scriptedText("不该被调用")]
    }

    /// 按用例标签构造固定路由（reply 直答 / tools 预置 / pass）。
    @ContextTreeActor
    private func fixtureRouter(_ label: String) -> any Router {
        if label.contains("reply") {
            return FixedRouter(.reply("本地直答"))
        }
        if label.contains("tools") {
            return FixedRouter(.tools([LlmToolCall(id: "c1", name: "get_time")]))
        }
        return FixedRouter(.pass)
    }

    // ─── planning-phase 分段 ───

    @ContextTreeActor
    private func checkPlanningPhase(_ fixture: S16Fixture) async throws {
        let expect = fixture.cases[0]["expect"]?.objectValue ?? [:]
        let session = try Session(id: "s1")
        let registry = ToolRegistry()
        _ = try registry.register(PlanTool(session: session))
        _ = try registry.register(GetTimeTool())
        let llm = ScriptedProvider([
            scriptedCall("c1", kPlanToolName, args: #"{"goal":"报时","steps":["问时间","回答"]}"#),
            scriptedText("12:00"),
        ])
        var config = AgentLoop.Config()
        config.session = session
        config.planning = true
        let loop = AgentLoop(llm: llm, tools: registry, config: config)
        let turn = try await loop.run("现在几点")
        #expect(turn.reply == expect["reply"]?.stringValue)
        #expect(llm.calls.count == expect["modelCalls"]?.intValue)
        #expect(readPlan(session)?.goal == expect["planGoal"]?.stringValue)
        #expect(llm.calls.last?.first?.content.contains("[当前计划]") == (expect["systemHasPlan"] == .bool(true)))
        #expect(session.events.map(\.type) == (expect["eventTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []))
    }

    @ContextTreeActor
    private func checkPlanningSkipped(_ fixture: S16Fixture) async throws {
        let expect = fixture.cases[1]["expect"]?.objectValue ?? [:]
        let llm = ScriptedProvider([scriptedText("直接回答")])
        var config = AgentLoop.Config()
        config.session = try Session(id: "s2")
        config.planning = true
        let loop = AgentLoop(llm: llm, tools: ToolRegistry(), config: config)
        let turn = try await loop.run("你好")
        #expect(turn.reply == expect["reply"]?.stringValue)
        #expect(llm.calls.count == expect["modelCalls"]?.intValue)
    }
}

/// 探针工具（固定风险级）。
@ContextTreeActor
private final class ProbeTool: Tool {
    let risk: ToolRisk
    init(risk: ToolRisk) {
        self.risk = risk
    }
    var name: String { "probe" }
    var description: String { "probe" }
    var riskLevel: ToolRisk { risk }
    func call(_ context: ToolContext) async throws -> ToolResult {
        .success("ok")
    }
}

/// 固定路由决策的路由器。
@ContextTreeActor
private final class FixedRouter: Router {
    let decision: RouteDecision
    init(_ decision: RouteDecision) {
        self.decision = decision
    }
    func route(_ input: String) async throws -> RouteDecision {
        decision
    }
}

/// 调用计数盒（invoke 闭包共享）。
@ContextTreeActor
private final class InvokeCounter {
    private(set) var count = 0
    func increment() {
        count += 1
    }
}

/// S16 fixture 装载。
struct S16Fixture {
    let name: String
    let kind: String
    let raw: JSONValue
    let cases: [JSONValue]
}

enum S16FixtureLoader {
    static func loadAllOrEmpty() -> [S16Fixture] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "spec/fixtures/s16", directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path()) else {
            return []
        }
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            guard let root = try? JSONValue.parse(Data(contentsOf: directory.appending(path: name))).objectValue else {
                return nil
            }
            return S16Fixture(
                name: root["name"]?.stringValue ?? name,
                kind: root["kind"]?.stringValue ?? "",
                raw: .object(root),
                cases: root["cases"]?.arrayValue ?? []
            )
        }
    }
}
