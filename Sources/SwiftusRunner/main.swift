import Foundation
import SwiftusCore
import SwiftusDemo

/// 离线 Demo 入口。
///
/// 跑通「提问 → 工具调用 → 回填 → 收口」，并顺带演示 W3 补上的接线：
/// 会话持久化、任务中心、提醒、定时任务交付、联网搜索、MCP server 工具。
/// 全程离线：脚本化模型 + 进程内 MCP server + 临时目录，无 Key、无网络。
@ContextTreeActor
func runDemo() async throws {
    let scenario = try await buildDemoScenario()
    defer { scenario.context.dispose() }

    // ── 1. Agent 闭环（含一次 MCP server 工具调用）──
    print("=== 1. Agent Loop ===")
    let question = "帮我算一下 19 加 23"
    print("用户:\(question)\n")
    let run = try await scenario.loop.run(question)
    for (index, step) in run.steps.enumerated() {
        for (callIndex, call) in step.toolCalls.enumerated() {
            print("第 \(index + 1) 轮 → 调用 \(call.name)(\(call.arguments))")
            print("         ← \(step.results[callIndex].content)\n")
        }
    }
    print("最终回答:\(run.answer)")

    // ── 2. 会话持久化：一条会话贯穿全程，flush 后落盘 ──
    print("\n=== 2. 会话持久化（S4）===")
    let task = try await scenario.tasks.create(kind: .agentTurn, description: "写一份周报")
    _ = try await scenario.schedule.create(
        prompt: "该交周报了",
        at: .string("2099-01-01T09:00:00Z")
    )
    _ = try scenario.cron.addDynamicTask(["prompt": .string("每日巡检"), "daily": .string("09:00")])
    // 手动触发一次：验证「到期 → 交付端口 → 同一条会话」的整条链路。
    // （不用 `tick()`——它按墙钟判到期，Demo 跑的时刻未必撞上 09:00，
    //   `runTaskNow` 才是「宿主立即触发」这条确定性路径。）
    if let cronTask = scenario.cron.listTasks().first {
        let record = try await scenario.cronRuntime.runTaskNow(cronTask.id)
        _ = scenario.cronRuntime.finishRun(record.id, ok: true, excerpt: "已交付到会话")
    }
    try await scenario.sessions.flush()

    let events = scenario.session.events
    print("会话 \(scenario.session.id) 事件数：\(events.count)")
    let byType = Dictionary(grouping: events, by: \.type).mapValues(\.count)
    for type in byType.keys.sorted() {
        print("  \(type)：\(byType[type] ?? 0) 条")
    }
    print("落盘会话 id：\(try await scenario.sessions.persistedIds())")

    // ── 3. 任务中心：状态写进同一条会话，可从事件流还原 ──
    print("\n=== 3. 任务中心（S17）===")
    print("任务 \(task.id) 状态：\(task.status.rawValue)")
    print("活跃任务：\(scenario.tasks.active.map { "\($0.id)=\($0.status.rawValue)" })")

    // ── 4. 提醒：`schedule/change` 折叠回活动记录 ──
    print("\n=== 4. 提醒（S8）===")
    let reminders = try scenario.schedule.fold().active
    print("活动提醒：\(reminders.map(\.id))")
    for reminder in reminders {
        print("  \(reminder.id)：\(reminder.prompt)")
    }

    // ── 5. 定时任务：独立 JSON 账本 + 交付记录 ──
    print("\n=== 5. 定时任务（S9）===")
    let cronTasks = scenario.cron.listTasks()
    print("cron 任务：\(cronTasks.map { "\($0.id)（\($0.prompt)）" })")
    let delivered = events.filter { $0.type == "cron/delivered" }
    print("本轮交付到会话：\(delivered.count) 条")
    for event in delivered {
        let data = event.data?.objectValue ?? [:]
        print("  \(data["prompt"]?.stringValue ?? "?") · \(data["framing"]?.stringValue ?? "")")
    }

    // ── 6. 联网搜索：缺 Key 时降级到免 Key 源（Demo 不真发请求）──
    print("\n=== 6. 联网搜索（S20）===")
    print("已注册源：\(scenario.search.registeredNames.joined(separator: " → "))")

    // ── 7. MCP：断连只注销本 server 的工具 ──
    print("\n=== 7. MCP（S11）===")
    print("已装配 server：\(scenario.mcp.servers)")
    print("已注册工具：\(scenario.mcp.tools(of: "demo").map(\.name))")
}

do {
    try await runDemo()
} catch {
    print("Demo 失败:\(error)")
    exit(1)
}
