import Foundation
import SwiftusAgent
import SwiftusCompaction
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM
import Testing

/// 规格 S4 增补刀：Agent Loop 核心闭环（对齐 Dart `agent_loop_test.dart`，
/// memory / planning / router / reflection 用例随后续刀补）。
@ContextTreeActor
@Suite("AgentLoop")
struct AgentLoopTests {
    @Test("纯文本回复：单步、无工具、schema 已下发")
    func plainTextReply() async throws {
        let provider = ScriptedProvider([scriptedText("你好")])
        let registry = ToolRegistry()
        _ = try registry.register(GetTimeTool())
        let loop = AgentLoop(llm: provider, tools: registry)

        let turn = try await loop.run("在吗")

        #expect(turn.reply == "你好")
        #expect(turn.steps.isEmpty)
        #expect(provider.calls.count == 1)
        #expect(provider.lastTools?.first?["name"] == .string("get_time"))
    }

    @Test("工具调用闭环：执行工具并回填后收口")
    func toolCallRoundTrip() async throws {
        let provider = ScriptedProvider([
            scriptedCall("c1", "get_time"),
            scriptedText("现在是 12:00"),
        ])
        let registry = ToolRegistry()
        _ = try registry.register(GetTimeTool())
        let loop = AgentLoop(llm: provider, tools: registry)

        let turn = try await loop.run("现在几点")

        #expect(turn.reply == "现在是 12:00")
        #expect(turn.steps.count == 1)
        #expect(turn.steps.first?.call.name == "get_time")
        #expect(turn.steps.first?.result.content == "12:00")
        let second = provider.calls[1]
        #expect(second[second.count - 2].toolCalls.first?.id == "c1")
        #expect(second.last?.role == "tool")
        #expect(second.last?.toolCallId == "c1")
        #expect(second.last?.content == "12:00")
    }

    @Test("工具失败作为结果回填，不中断循环")
    func toolFailureFedBack() async throws {
        let provider = ScriptedProvider([
            scriptedCall("c1", "get_time"),
            scriptedText("时钟暂时不可用"),
        ])
        let registry = ToolRegistry()
        _ = try registry.register(FailingTimeTool())
        let loop = AgentLoop(llm: provider, tools: registry)

        let turn = try await loop.run("现在几点")

        #expect(turn.steps.first?.result.failed == true)
        #expect(turn.reply == "时钟暂时不可用")
        #expect(provider.calls.count == 2)
    }

    @Test("事件落盘并可由 deriveAgentMessages 还原")
    func eventsRecorded() async throws {
        let session = try Session(id: "s1")
        let provider = ScriptedProvider([scriptedCall("c1", "get_time"), scriptedText("12:00")])
        let registry = ToolRegistry()
        _ = try registry.register(GetTimeTool())
        var config = AgentLoop.Config()
        config.session = session
        let loop = AgentLoop(llm: provider, tools: registry, config: config)

        try await loop.run("现在几点")

        #expect(session.events.map(\.type) == [
            SessionEventKind.userMessage,
            SessionEventKind.assistantMessage,
            SessionEventKind.toolResult,
            SessionEventKind.assistantMessage,
        ])
        let restored = deriveAgentMessages(session.events)
        #expect(restored.count == 4)
        #expect(restored[0].role == "user")
        #expect(restored[1].toolCalls.first?.id == "c1")
        #expect(restored[2].toolCallId == "c1")
        #expect(restored[3].content == "12:00")
    }

    @Test("会话在循环中被关闭则中止")
    func closedSessionAborts() async throws {
        let session = try Session(id: "s1")
        session.close()
        var config = AgentLoop.Config()
        config.session = session
        let loop = AgentLoop(
            llm: ScriptedProvider([scriptedText("x")]),
            tools: ToolRegistry(),
            config: config
        )
        await #expect(throws: AgentLoopError.sessionClosed("s1")) {
            try await loop.run("hi")
        }
    }

    @Test("systemPrompt 装配进 system 消息；动态上下文与闭包 text 下一轮生效")
    func systemPromptAssembly() async throws {
        let prompt = SystemPrompt()
        _ = try prompt.section(PromptSection(name: "persona", text: { "你是助手。" }))
        let provider = ScriptedProvider([scriptedText("好的"), scriptedText("好的")])
        var config = AgentLoop.Config()
        config.systemPrompt = prompt
        let loop = AgentLoop(llm: provider, tools: ToolRegistry(), config: config)

        try await loop.run("你好")
        #expect(provider.calls.first?.first?.role == "system")
        #expect(provider.calls.first?.first?.content == "你是助手。")

        _ = try prompt.context(PromptContext(name: "time", order: -10, text: { "[当前时间]\n2026-09-16 周三" }))
        try await loop.run("今天几号")
        #expect(provider.calls.last?.first?.content == "你是助手。\n\n[当前时间]\n2026-09-16 周三")
    }

    @Test("压缩：超预算时产出摘要并窗口化历史")
    func compactionWindowsHistory() async throws {
        let session = try Session(id: "s1")
        for index in 0..<4 {
            try session.append(SessionEventKind.userMessage, data: .object(["text": .string("第\(index)条")]))
        }
        let compactor = try Compactor(keepRecent: 1)
        let provider = ScriptedProvider([scriptedText("这是摘要"), scriptedText("最终回复")])
        var config = AgentLoop.Config()
        config.session = session
        config.compactor = compactor
        let loop = AgentLoop(llm: provider, tools: ToolRegistry(), config: config)

        let turn = try await loop.run("新问题")

        #expect(compactor.summaryOf("s1") == "这是摘要")
        #expect(provider.calls.count == 2)
        #expect(provider.calls.last?.first?.content.contains("[历史摘要]") == true)
        #expect(provider.calls.last?.first?.content.contains("这是摘要") == true)
        #expect(session.events.map(\.type) == [
            SessionEventKind.userMessage, SessionEventKind.userMessage,
            SessionEventKind.userMessage, SessionEventKind.userMessage,
            SessionEventKind.userMessage,
            CompactionEventKind.start, CompactionEventKind.summary, CompactionEventKind.end,
            SessionEventKind.assistantMessage,
        ])
        #expect(checkCompactionInvariant(session.events).isEmpty)
        #expect(turn.reply == "最终回复")
    }

    @Test("取消竞速：取消后 run 以 AgentCancelled 结束")
    func cancelRaces() async throws {
        let provider = ScriptedProvider([scriptedText("不该到达")])
        provider.hang = true
        let loop = AgentLoop(llm: provider, tools: ToolRegistry())
        let cancel = AgentCancel()
        cancel.cancel()
        await #expect(throws: AgentCancelled()) {
            try await loop.run("hi", cancel: cancel)
        }
    }

    @Test("provideAgentLoop：依赖 llm + tools，作为 agentLoop 服务提供")
    func provideAssembles() async throws {
        let ctx = Context.root()
        _ = try ctx.provide(.llm, ScriptedProvider([scriptedText("hi")]))
        let registry = ToolRegistry()
        _ = try ctx.provide(.tools, registry)

        let loop = try provideAgentLoop(ctx, maxSteps: 3)

        #expect(try ctx.require(.agentLoop) === loop)
        #expect(try await loop.run("x").reply == "hi")
        ctx.dispose()
    }
}
