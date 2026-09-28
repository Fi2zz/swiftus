import Foundation
import SwiftusAgent
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM
import Testing

/// 规格 S16 §9/§10 golden fixtures：plan-mode / prompt-evolver。
@Suite("S16 plan-mode & prompt-evolver fixtures")
struct S16EvolutionFixtureTests {
    private static let fixtures = S16FixtureLoader.loadAllOrEmpty()

    @Test("plan-mode-flow", arguments: Self.fixtures.filter { $0.kind == "plan-mode-flow" })
    @ContextTreeActor
    func planModeFlow(_ fixture: S16Fixture) async throws {
        let expect = fixture.raw["expect"]?.objectValue ?? [:]
        let session = try Session(id: "p1")
        let prompt = SystemPrompt()
        _ = try prompt.section(PromptSection(name: "persona", text: { "你是助手。" }))
        let approval = AutoApproval(true)
        let planMode = DefaultPlanMode(session: session, prompt: prompt, approval: approval)
        let registry = ToolRegistry()
        _ = try registry.register(GatedTool("read", .low))
        _ = try registry.register(GatedTool("write", .medium))
        let ctx = Context.root()
        defer { ctx.dispose() }
        try ctx.provide(.tools, registry)
        try providePlanMode(ctx, planMode: planMode, prompt: prompt, approval: approval, tools: registry)
        planMode.enter()
        let lowOk = await registry.call(ToolCall(name: "read"))
        let assembledActive = prompt.assemble().sections.map(\.name)
        let blocked = await registry.call(ToolCall(name: "write"))
        let exitOk = await registry.call(ToolCall(name: kExitPlanModeToolName, arguments: [
            "goal": .string("改文档"),
            "steps": .array([.string("读"), .string("写")]),
        ]))
        #expect(assembledActive.contains("plan:policy") == (expect["policyInjected"] == .bool(true)))
        #expect(lowOk.failed == (expect["lowOkFailed"] == .bool(true)))
        #expect(blocked.failed == (expect["blockedFailed"] == .bool(true)))
        #expect(blocked.error?.code == expect["blockedCode"]?.stringValue)
        #expect(exitOk.content == expect["exitReply"]?.stringValue)
        #expect(planMode.state.rawValue == expect["stateAfterExit"]?.stringValue)
        #expect(session.events.map(\.type) == (expect["sessionEvents"]?.arrayValue?.compactMap(\.stringValue) ?? []))
    }

    @Test("prompt-evolver-flow", arguments: Self.fixtures.filter { $0.kind == "prompt-evolver-flow" })
    @ContextTreeActor
    func promptEvolverFlow(_ fixture: S16Fixture) async throws {
        let expect = fixture.raw["expect"]?.objectValue ?? [:]
        let prompt = SystemPrompt()
        _ = try prompt.section(PromptSection(name: "persona", text: { "你是助手。" }))
        let llm = ScriptedProvider([
            scriptedText("失败模式：指令不够具体"),
            scriptedText("改进后的 persona：更具体地要求工具。"),
        ])
        let evalLlm = ScriptedProvider([scriptedText("回答")])
        let evalRegistry = ToolRegistry()
        _ = try evalRegistry.register(GetTimeTool())
        let evalAgent = AgentLoop(llm: evalLlm, tools: evalRegistry)
        let evaluator = Evaluator(run: { input in try await evalAgent.run(input) })
        let evolver = DefaultPromptEvolver(
            llm: llm,
            evaluator: evaluator,
            prompt: prompt,
            evalCases: [EvalCase(id: "a", input: "现在几点", expectedOutput: "回答")],
            minTraces: 3
        )
        let fakeTrace = SessionEvent(seq: 0, type: SessionEventKind.toolResult, time: Date(), data: .object([
            "name": .string("get_time"),
            "content": .string("错误"),
        ]), sessionId: "s")
        let insufficient = try await evolver.propose(sectionName: "persona", lowQualityTraces: [])
        #expect((insufficient == nil) == (expect["insufficientNull"] == .bool(true)))
        let proposed = try #require(try await evolver.propose(sectionName: "persona", lowQualityTraces: [fakeTrace, fakeTrace, fakeTrace]))
        #expect(proposed.sectionName == expect["proposedSection"]?.stringValue)
        #expect((proposed.parentId == nil) == (expect["proposedParentNull"] == .bool(true)))
        let evaluated = try await evolver.evaluate(proposed)
        #expect(evaluated.decision.rawValue == expect["evaluatedDecision"]?.stringValue)
        #expect(evaluated.improvement == doubleOf(expect["evaluatedImprovement"]))
        let promoted = try await evolver.promote(proposed, threshold: 0.05)
        #expect(promoted == (expect["promoted"] == .bool(true)))
        await #expect(throws: PromptEvolverError.variantNotFound("ghost")) {
            try await evolver.rollback("ghost")
        }
    }
}

/// JSONValue 数值读取。
private func doubleOf(_ value: JSONValue?) -> Double? {
    if case let .double(number) = value { return number }
    if case let .int(number) = value { return Double(number) }
    return nil
}
