import SwiftusCore
import SwiftusDemo
import SwiftusFoundation
import Testing

/// Demo 接线验收：一条会话贯穿 Agent Loop / 任务 / 提醒 / 定时任务，
/// `flush()` 后全部落在同一份 JSONL 里。
///
/// 与 `CompositionWiringTests` 的分工：那边守**库**的接线（不依赖 Demo），
/// 这边守 **Demo 场景本身没接错**——Demo 是使用者照着抄的样板，接错了会被
/// 静默复制到真实项目里。
@ContextTreeActor
@Suite("Demo 场景接线")
struct DemoWiringTests {

    @Test("任务 / 提醒 / 定时任务交付全落进同一条会话事件流")
    func sharedSession() async throws {
        let scenario = try await buildDemoScenario()
        defer { scenario.context.dispose() }

        // 任务与提醒各写一条事件。
        let task = try await scenario.tasks.create(kind: .agentTurn, description: "写周报")
        _ = try await scenario.schedule.create(
            prompt: "该交周报了",
            at: .string("2099-01-01T09:00:00Z")
        )
        #expect(scenario.session.events.contains { $0.type == "task/changed" })
        #expect(scenario.session.events.contains { $0.type == "schedule/change" })

        // 定时任务走独立账本，但到期经交付端口送回**同一条**会话。
        _ = try scenario.cron.addDynamicTask(["prompt": .string("巡检"), "daily": .string("09:00")])
        let cronTask = try #require(scenario.cron.listTasks().first)
        let record = try await scenario.cronRuntime.runTaskNow(cronTask.id)
        _ = scenario.cronRuntime.finishRun(record.id, ok: true, excerpt: "已交付")

        let delivered = scenario.session.events.filter { $0.type == "cron/delivered" }
        #expect(delivered.count == 1, "定时任务应交付到会话，实际 \(delivered.count) 条")
        let payload = delivered.first?.data?.objectValue ?? [:]
        #expect(payload["prompt"]?.stringValue == "巡检")
        #expect((payload["framing"]?.stringValue ?? "").contains("巡检"), "framing 应带任务正文")

        // 一次 flush 让全链落定。
        try await scenario.sessions.flush()
        #expect(try await scenario.sessions.persistedIds() == ["demo"])

        // 任务可从事件流还原（执行环境已丢失 → 活跃任务标 failed，S17 §2）。
        try scenario.tasks.restore(scenario.session)
        let restored = try #require(scenario.tasks.get(task.id), "任务应能从事件流还原")
        #expect(restored.description == "写周报")
    }

    @Test("Demo 的工具表同时装着本地工具、任务工具、cron 工具与 MCP 工具")
    func toolTableComposition() async throws {
        let scenario = try await buildDemoScenario()
        defer { scenario.context.dispose() }
        let tools = try scenario.context.require(.tools)
        let names = Set(tools.names)
        // 本地工具
        #expect(names.contains("add"))
        // S17 的两个任务工具
        #expect(names.contains("list_tasks"))
        #expect(names.contains("cancel_task"))
        // S9 的五个 cron 工具
        #expect(names.contains("cron_list"))
        #expect(names.contains("cron_add"))
        // S11 的 MCP 工具
        #expect(names.contains("demo__shout"))
    }

    @Test("MCP server 断连只注销它自己的工具，其余工具表照常")
    func mcpDisconnectIsIsolated() async throws {
        let scenario = try await buildDemoScenario()
        defer { scenario.context.dispose() }
        let tools = try scenario.context.require(.tools)
        let before = Set(tools.names)
        #expect(before.contains("demo__shout"))

        // 关闭注册表（等价于全部 server 断连）。
        await scenario.mcp.close()

        let after = Set(tools.names)
        #expect(after.isEmpty == false, "其余工具不应被一起清掉")
        #expect(after.contains("add"), "本地工具应保留")
        #expect(after.contains("list_tasks"), "任务工具应保留")
        #expect(after.contains("cron_list"), "cron 工具应保留")
        #expect(after.contains("demo__shout") == false, "断连 server 的工具应被注销")
    }
}
