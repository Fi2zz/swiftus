import SwiftusCore
import SwiftusDemo
import SwiftusFoundation
import SwiftusLLM
import Testing

/// W1 收口验收:离线 Demo「提问 → 工具调用 → 回填 → 收口」端到端(脚本化模型,无需 Key)。
@ContextTreeActor
@Suite("W1 端到端闭环")
struct MiniAgentLoopTests {
    @Test("技能目录 → skill 工具 → 按指令调 add → 收口")
    func endToEnd() async throws {
        let scenario = try await buildDemoScenario()
        defer { scenario.context.dispose() }

        let run = try await scenario.loop.run("帮我算一下 19 加 23")

        // 两轮工具调用:先 skill 后 add,模型按技能指令行动
        #expect(run.steps.count == 2)
        #expect(run.steps[0].toolCalls.first?.name == "skill")
        #expect(run.steps[0].results.first?.content.contains("我来算一下") == true)
        #expect(run.steps[1].toolCalls.first?.name == "add")
        #expect(run.steps[1].results.first?.content == "42")
        #expect(run.answer.contains("42"))

        // 第一次请求:system 消息含技能目录段,工具投影含 add 与 skill
        let firstRequest = try #require(scenario.llm.requests.first)
        #expect(firstRequest.messages.first?.content.contains("<available_skills>") == true)
        #expect(firstRequest.messages.first?.content.contains("calculator-manners") == true)
        #expect(firstRequest.tools?.contains { $0["name"] == .string("add") } == true)
        #expect(firstRequest.tools?.contains { $0["name"] == .string("skill") } == true)

        // 第三次请求(收口前):消息历史里有工具结果回填
        let lastRequest = try #require(scenario.llm.requests.last)
        #expect(lastRequest.messages.contains { $0.role == "tool" && $0.toolCallId == "call_2" })
    }

    @Test("超过 maxRounds 仍请求工具则快速失败")
    func roundsExhausted() async throws {
        let tools = ToolRegistry()
        try tools.fn("noop", description: "空转") { _ in .success("ok") }
        let scripted = ScriptedLlm(responses: [
            { _ in
                var result = LlmResult(content: "", provider: "scripted", model: "offline")
                result.toolCalls = [LlmToolCall(id: "c1", name: "noop")]
                return result
            },
            { _ in
                var result = LlmResult(content: "", provider: "scripted", model: "offline")
                result.toolCalls = [LlmToolCall(id: "c2", name: "noop")]
                return result
            },
        ])
        let loop = MiniAgentLoop(llm: scripted, tools: tools, systemPrompt: "")
        await #expect(throws: MiniAgentError.roundsExhausted(2)) {
            _ = try await loop.run("转起来", maxRounds: 2)
        }
    }
}
