import SwiftusCore
import SwiftusDemo
import SwiftusFoundation
import SwiftusLLM
import Testing

/// W1 收口验收:离线 Demo「提问 → 工具调用 → 回填 → 收口」端到端(脚本化模型,无需 Key)。
@ContextTreeActor
@Suite("W1 端到端闭环")
struct MiniAgentLoopTests {
    @Test("技能目录 → skill → add → MCP server 工具 → 收口")
    func endToEnd() async throws {
        let scenario = try await buildDemoScenario()
        defer { scenario.context.dispose() }

        let run = try await scenario.loop.run("帮我算一下 19 加 23")

        // 三轮工具调用:先 skill 再 add(本地),最后调 MCP server 上的工具
        #expect(run.steps.count == 3)
        #expect(run.steps[0].toolCalls.first?.name == "skill")
        #expect(run.steps[0].results.first?.content.contains("我来算一下") == true)
        #expect(run.steps[1].toolCalls.first?.name == "add")
        #expect(run.steps[1].results.first?.content == "42")
        #expect(run.steps[2].toolCalls.first?.name == "demo__shout")
        #expect(run.steps[2].results.first?.content == "42!")
        #expect(run.answer.contains("42"))

        // 第一次请求:system 消息含技能目录段,工具投影含 add、skill 与 MCP 工具。
        // MCP server 的工具与本地工具在模型眼里没有区别——这正是接 MCP 的意义
        let firstRequest = try #require(scenario.llm.requests.first)
        #expect(firstRequest.messages.first?.content.contains("<available_skills>") == true)
        #expect(firstRequest.messages.first?.content.contains("calculator-manners") == true)
        #expect(firstRequest.tools?.contains { $0["name"] == .string("add") } == true)
        #expect(firstRequest.tools?.contains { $0["name"] == .string("skill") } == true)
        #expect(firstRequest.tools?.contains { $0["name"] == .string("demo__shout") } == true)

        // MCP 工具的入参 schema 由服务端下发、原样透传给模型(规格 S11 §7)
        let mcpTool = try #require(firstRequest.tools?.first { $0["name"] == .string("demo__shout") })
        #expect(mcpTool["parameters"]?["required"] == .array([.string("text")]))
        #expect(mcpTool["description"] == .string("把文本转成大写并加感叹号（演示用的 MCP 工具）"))

        // 收口前的最后一次请求:消息历史里有全部三轮工具结果回填
        let lastRequest = try #require(scenario.llm.requests.last)
        #expect(lastRequest.messages.contains { $0.role == "tool" && $0.toolCallId == "call_2" })
        #expect(lastRequest.messages.contains { $0.role == "tool" && $0.toolCallId == "call_3" })
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
