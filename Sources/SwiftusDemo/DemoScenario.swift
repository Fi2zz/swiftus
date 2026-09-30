import Foundation
import SwiftusCore
import SwiftusCron
import SwiftusFoundation
import SwiftusLLM
import SwiftusMCP
import SwiftusSchedule
import SwiftusSearch
import SwiftusSkill
import SwiftusTasks

/// 装配好的离线 Demo 场景。
public struct DemoScenario {
    public let context: Context
    public let loop: MiniAgentLoop
    public let llm: ScriptedLlm
    /// 会话（Agent Loop / 任务 / 提醒共用同一条事件流，规格 S4 §6）。
    public let session: Session
    /// 会话仓库（接了 JSONL 持久化，`flush()` 让全链落定）。
    public let sessions: SessionStore
    /// 已装配的 MCP 注册表（Demo 用进程内 server，不连网络）。
    public let mcp: McpRegistry
    /// 任务中心。
    public let tasks: any TaskCenter
    /// 提醒（`schedule/change` 的唯一权威是会话事件流，规格 S8 §2）。
    public let schedule: SessionSchedule
    /// 定时任务服务。
    public let cron: CronService
    /// 定时任务运行时（到期经 `deliver` 送进同一会话）。
    public let cronRuntime: CronRuntime
    /// 联网搜索 / 抓取服务。
    public let search: SearchService
}

/// 装配离线 Demo 的 Context 树与脚本化模型（验收：提问 → 工具调用 → 回填 → 收口）。
///
/// 场景覆盖六块拼图，全部**离线**（脚本化模型 + 进程内 MCP server + 内存存储，
/// 不需要任何 Key、不发任何网络请求）：
/// 1. 模型从技能目录看到 `calculator-manners`，先用 `skill` 工具加载它；
/// 2. 按技能指令（『先说「我来算一下」』）发起 `add` 调用；
/// 3. 调 MCP server 上的工具（S11：`server__tool` 与本地工具在模型眼里没有区别）；
/// 4. 会话持久化（S4）：一条会话贯穿 Agent Loop / 任务 / 提醒，`flush()` 后落盘；
/// 5. 任务中心（S17）与提醒（S8）把状态写进**同一条**会话事件流；
/// 6. 定时任务（S9）有独立 JSON 账本，到期经 `deliver` 端口投递回同一会话。
///
/// 第 4–6 段是 W3 的接线验收：各域单测全绿并不代表「串起来也对」——
// `CompositionWiringTests` 专门守这件事。
@ContextTreeActor
public func buildDemoScenario() async throws -> DemoScenario {
    let app = Context.root(name: "demo")
    let tools = try provideTools(app)
    let prompt = try provideSystemPrompt(app)
    let registry = try await provideSkillRegistry(app)
    _ = try provideSkillCatalog(app)
    _ = try provideSkillTool(app)

    try registry.register(SkillRegistration(
        name: "calculator-manners",
        description: "做算术时的礼仪",
        content: "调用 add 工具前，先说『我来算一下』。"
    ))
    await registry.refresh()

    try tools.fn("add", description: "两个整数相加", params: [
        .integer("a", required: true),
        .integer("b", required: true),
    ]) { context in
        let lhs = try context.integer("a") ?? 0
        let rhs = try context.integer("b") ?? 0
        return .success("\(lhs + rhs)")
    }

    // ── S4：一条会话贯穿全程（事件流是所有状态的唯一权威）──
    // Demo 落盘到临时目录，跑完即弃；生产场景换 `SwiftusHome` 下的固定目录。
    let demoDirectory = FileManager.default.temporaryDirectory
        .appending(path: "swiftus-demo-\(UUID().uuidString)")
    let persistence = try JsonlSessionPersistence(directory: demoDirectory.path())
    let sessions = try provideSessions(app, persistence: persistence)
    let session = try sessions.create(id: "demo")

    // ── S17：任务中心，事件写进同一条会话 ──
    var taskConfig = TaskCenterConfig()
    taskConfig.session = session
    let tasks = try provideTaskCenter(app, config: taskConfig)

    // ── S8：提醒，唯一权威就是会话里的 `schedule/change` 事件 ──
    let schedule = try provideSessionSchedule(
        app,
        session: session,
        // 每次变更后立刻落盘，别等上下文释放。
        flush: { try await sessions.flush() }
    )

    // ── S9：定时任务有独立 JSON 账本；到期经交付端口送回同一会话 ──
    let cronDirectory = demoDirectory.appending(path: "cron")
    let cronStorage = JsonCronStorage(
        tasksPath: cronDirectory.appending(path: "tasks.json").path(),
        historyPath: cronDirectory.appending(path: "history.jsonl").path()
    )
    let cron = CronService(storage: cronStorage, timeZone: TimeZone(identifier: "UTC")!)
    try app.provide(.cron, cron)
    _ = try provideCronTools(app, callerSessionId: session.id)
    let cronRuntime = CronRuntime(
        service: cron,
        deliver: { recordId, framing, task in
            try session.append("cron/delivered", data: .object([
                "recordId": .string(recordId),
                "framing": .string(framing),
                "prompt": .string(task.prompt),
            ]))
            return true
        },
        options: CronRuntimeOptions(
            // Demo 不跑真实 tick（`firstTickDelay` 极长）：手动 `tick()` 即可验证交付路径。
            firstTickDelay: .seconds(3600)
        )
    )

    // ── S20：联网搜索与抓取（Demo 不真发请求；缺 Key 时降级到免 Key 源）──
    let search = try provideSearch(app, timeout: 5)
    _ = try provideWebTools(app)

    // ── S11：装配一台 MCP server（进程内替身；真实场景传 McpServerConfig）──
    let mcp = try await provideMcp(
        app,
        [try McpServerConfig(name: "demo", type: .stdio, command: "demo-in-process")],
        transportFactory: { _ in DemoMcpTransport() }
    )

    let scripted = ScriptedLlm(responses: [
        { _ in
            var result = LlmResult(content: "", provider: "scripted", model: "offline")
            result.toolCalls = [LlmToolCall(
                id: "call_1",
                name: "skill",
                arguments: #"{"name":"calculator-manners"}"#
            )]
            return result
        },
        { _ in
            var result = LlmResult(content: "我来算一下", provider: "scripted", model: "offline")
            result.toolCalls = [LlmToolCall(
                id: "call_2",
                name: "add",
                arguments: #"{"a":19,"b":23}"#
            )]
            return result
        },
        { _ in
            // 调 MCP server 上的工具（全名带 server 前缀，保持调用日志里的归属）。
            var result = LlmResult(content: "算完了，再让 MCP server 复述一遍", provider: "scripted", model: "offline")
            result.toolCalls = [LlmToolCall(
                id: "call_3",
                name: "demo__shout",
                arguments: #"{"text":"42"}"#
            )]
            return result
        },
        { _ in
            LlmResult(content: "19 + 23 = 42，算完了；MCP server 复述为 42!。", provider: "scripted", model: "offline")
        },
    ])

    let systemText = prompt.render(prompt.assemble())
    let loop = MiniAgentLoop(llm: scripted, tools: tools, systemPrompt: systemText)
    return DemoScenario(
        context: app,
        loop: loop,
        llm: scripted,
        session: session,
        sessions: sessions,
        mcp: mcp,
        tasks: tasks,
        schedule: schedule,
        cron: cron,
        cronRuntime: cronRuntime,
        search: search
    )
}
