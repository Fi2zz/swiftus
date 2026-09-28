import Foundation
import SwiftusAgent
import SwiftusCore
import SwiftusFoundation
import SwiftusSchedule
import SwiftusTasks
import Testing

/// 规格 S17 的常规单元测试：守住 fixtures 之外、且与事件循环时机无关的语义
/// 关键点（变更流、装配与释放可逆、能力缝降级、解码边界、追踪元数据）。
@Suite("S17 任务中心单元")
struct TaskCenterTests {
    // MARK: 变更流

    @Test("changes 广播每次变更，dispose 后流结束")
    @ContextTreeActor
    func changesBroadcast() async throws {
        let harness = try TaskHarness()
        harness.startCollecting()
        let created = try await harness.center.create(kind: .custom, description: "x", parentTaskId: nil, metadata: [:])
        _ = try await harness.center.update(created.id, status: .running, result: nil, error: nil)
        _ = try await harness.center.update(created.id, status: .failed, result: nil, error: .string("崩了"))
        await harness.waitForChanges(3)
        #expect(harness.changes.map(\.status) == [.pending, .running, .failed])
        #expect(harness.changes.last?.error == .string("崩了"))

        // dispose 后订阅立即结束（不再接收新事件）。
        harness.center.dispose()
        var finished = false
        let stream = harness.center.changes
        _Concurrency.Task {
            for await _ in stream { Issue.record("dispose 后不应再收到事件") }
            finished = true
        }
        for _ in 0..<200 {
            if finished { break }
            try await _Concurrency.Task.sleep(for: .milliseconds(2))
        }
        #expect(finished)
    }

    // MARK: 装配与释放可逆

    @Test("provideTaskCenter 注册服务与两个工具，随上下文释放")
    @ContextTreeActor
    func provideTaskCenterAssembly() async throws {
        let ctx = Context.root()
        let tools = try provideTools(ctx)
        let session = try Session(id: "s1")
        let center = try provideTaskCenter(ctx, config: {
            var config = TaskCenterConfig()
            config.session = session
            return config
        }())
        #expect(ctx.get(.tasks) != nil)
        #expect(tools.get(kListTasksToolName) != nil)
        #expect(tools.get(kCancelTasksToolName) != nil)
        #expect(tools.get(kCancelTasksToolName)?.riskLevel == .medium)
        #expect(tools.get(kListTasksToolName)?.riskLevel == .low)

        ctx.dispose()
        #expect(ctx.get(.tasks) == nil)
        #expect(tools.get(kListTasksToolName) == nil)
        // 释放后中心不可用。
        await #expect(throws: TaskError.disposed) {
            try await center.create(kind: .custom, description: "x", parentTaskId: nil, metadata: [:])
        }
    }

    @Test("registerTools = false 时只提供服务不注册工具")
    @ContextTreeActor
    func provideTaskCenterWithoutTools() throws {
        let ctx = Context.root()
        let tools = try provideTools(ctx)
        var config = TaskCenterConfig()
        config.registerTools = false
        _ = try provideTaskCenter(ctx, config: config)
        #expect(ctx.get(.tasks) != nil)
        #expect(tools.get(kListTasksToolName) == nil)
        ctx.dispose()
    }

    @Test("provideTaskTracking 挂轮次钩子与 spawn_agent 中间件，释放后摘除")
    @ContextTreeActor
    func provideTaskTrackingAssembly() async throws {
        let ctx = Context.root()
        let tools = try provideTools(ctx)
        var loopConfig = AgentLoop.Config()
        loopConfig.session = try Session(id: "s1")
        let loop = AgentLoop(llm: S17ScriptedProvider([s17Text("hi")]), tools: tools, config: loopConfig)
        try ctx.provide(.agentLoop, loop)

        let center = try provideTaskCenter(ctx)
        let tracking = try provideTaskTracking(ctx)
        #expect(loop.turnTracker != nil)
        #expect(center.all.isEmpty)

        _ = try await loop.run("在吗")
        let turn = center.all.first { $0.kind == .agentTurn }
        #expect(turn?.status == .completed)
        #expect(turn?.result == .string("hi"))
        #expect(tracking.currentTurnTaskId == nil)

        ctx.dispose()
        #expect(loop.turnTracker == nil)
    }

    @Test("agentLoop 后到时轮次钩子自动挂上（inject 等待依赖）")
    @ContextTreeActor
    func provideTaskTrackingLateAgentLoop() async throws {
        let ctx = Context.root()
        let tools = try provideTools(ctx)
        let center = try provideTaskCenter(ctx)
        _ = try provideTaskTracking(ctx)

        // agentLoop 尚未提供：钩子不挂，追踪器空转。
        let loop = AgentLoop(llm: S17ScriptedProvider([s17Text("hi")]), tools: tools)
        #expect(loop.turnTracker == nil)
        let removeAgentLoop = try ctx.provide(.agentLoop, loop)
        #expect(loop.turnTracker != nil)
        _ = try await loop.run("在吗")
        #expect(center.all.contains { $0.kind == .agentTurn && $0.status == .completed })

        // 依赖消失：钩子自动摘除。
        try removeAgentLoop()
        #expect(loop.turnTracker == nil)
        ctx.dispose()
    }

    @Test("AgentLoop 未挂追踪器时行为不变")
    @ContextTreeActor
    func agentLoopWithoutTracker() async throws {
        let loop = AgentLoop(llm: S17ScriptedProvider([s17Text("hi")]), tools: ToolRegistry())
        #expect(loop.turnTracker == nil)
        let turn = try await loop.run("在吗")
        #expect(turn.reply == "hi")
    }

    // MARK: 能力缝降级

    @Test("缺 approval / telemetry / session 时降级不报错")
    @ContextTreeActor
    func degradeWithoutSeams() async throws {
        let center = try DefaultTaskCenter(clock: s17FixedClock)
        let task = try await center.create(kind: .custom, description: "x", parentTaskId: nil, metadata: [:])
        _ = try await center.update(task.id, status: .running, result: nil, error: nil)
        try await center.cancel(task.id)
        #expect(center.get(task.id)?.status == .cancelled)
    }

    @Test("上下文里的 approval / telemetry 缝惰性解析")
    @ContextTreeActor
    func resolveSeamsFromContext() async throws {
        let ctx = Context.root()
        let telemetry = try InMemoryTelemetry()
        try ctx.provide(.telemetry, telemetry)
        let approval = RecordingApproval(false)
        try ctx.provide(.approval, approval)
        let center = try DefaultTaskCenter(ctx: ctx, clock: s17FixedClock)
        let shell = try await center.create(kind: .shell, description: "sleep 1", parentTaskId: nil, metadata: [:])
        await #expect(throws: TaskError.cancelled) {
            try await center.cancel(shell.id)
        }
        #expect(approval.requests.count == 1)
        ctx.dispose()
    }

    // MARK: 解码与查询边界

    @Test("createdAt 缺失或非法抛 invalid-created-at")
    func invalidCreatedAt() {
        #expect(throws: TaskError.invalidCreatedAt) {
            try Task(jsonValue: .object(["id": .string("x")]))
        }
        #expect(throws: TaskError.invalidCreatedAt) {
            try Task(jsonValue: .object([
                "id": .string("x"),
                "createdAt": .string("不是时刻"),
            ]))
        }
    }

    @Test("恢复时遇到非法 createdAt 直接抛错")
    @ContextTreeActor
    func restoreWithCorruptEvent() throws {
        let session = try Session(id: "s1")
        try session.append(kTaskEvent, data: .object(["id": .string("x")]))
        #expect(throws: TaskError.invalidCreatedAt) {
            try DefaultTaskCenter(session: session, clock: s17FixedClock)
        }
    }

    @Test("未知任务的树查询返回空，registerCancel 允许覆盖")
    @ContextTreeActor
    func treeEdges() async throws {
        let center = try DefaultTaskCenter(clock: s17FixedClock)
        #expect(center.subtree(of: "ghost").isEmpty)
        #expect(center.children(of: "ghost").isEmpty)
        #expect(center.get("ghost") == nil)

        let task = try await center.create(kind: .custom, description: "x", parentTaskId: nil, metadata: [:])
        var calls: [String] = []
        center.registerCancel(task.id) { calls.append("first") }
        center.registerCancel(task.id) { calls.append("second") }
        try await center.cancel(task.id)
        #expect(calls == ["second"])
    }

    @Test("cancelChildren 不取消自己，只取消活跃子任务")
    @ContextTreeActor
    func cancelChildrenOnly() async throws {
        let center = try DefaultTaskCenter(clock: s17FixedClock)
        let root = try await center.create(kind: .custom, description: "root", parentTaskId: nil, metadata: [:])
        let active = try await center.create(kind: .custom, description: "a", parentTaskId: root.id, metadata: [:])
        let done = try await center.create(kind: .custom, description: "b", parentTaskId: root.id, metadata: [:])
        _ = try await center.update(done.id, status: .completed, result: nil, error: nil)
        try await center.cancelChildren(of: root.id)
        #expect(center.get(root.id)?.status == .pending)
        #expect(center.get(active.id)?.status == .cancelled)
        #expect(center.get(done.id)?.status == .completed)
    }

    @Test("恢复前先 cancel 过：级联取消遇到已终态子任务静默跳过")
    @ContextTreeActor
    func cascadeSkipsTerminalChildren() async throws {
        let center = try DefaultTaskCenter(clock: s17FixedClock)
        let root = try await center.create(kind: .custom, description: "root", parentTaskId: nil, metadata: [:])
        let child = try await center.create(kind: .custom, description: "child", parentTaskId: root.id, metadata: [:])
        _ = try await center.update(child.id, status: .completed, result: nil, error: nil)
        try await center.cancel(root.id)
        #expect(center.get(root.id)?.status == .cancelled)
        #expect(center.get(child.id)?.status == .completed)
    }

    // MARK: 追踪元数据

    @Test("TaskTracking 把 goalId 与 planMode 写入轮次任务元数据")
    @ContextTreeActor
    func trackingMetadata() async throws {
        let ctx = Context.root()
        let center = try DefaultTaskCenter(ctx: ctx, clock: s17FixedClock)
        _ = try provideTools(ctx)
        _ = try provideGoal(ctx, config: {
            var config = GoalConfig()
            config.goal = DefaultGoalService()
            return config
        }())
        let goal = try await ctx.require(.goal).create("盯航班", maxRounds: nil)
        #expect(goal.id != "")
        let planMode = try providePlanMode(ctx, planMode: nil, tools: nil, telemetry: nil)
        planMode.enter()

        let tracking = TaskTracking(tasks: center, ctx: ctx)
        try await tracking.beginTurn("查机票")
        let turn = center.all.first { $0.kind == .agentTurn }
        #expect(turn?.metadata["goalId"] == .string(goal.id))
        #expect(turn?.metadata["planMode"] == .bool(true))
        try await tracking.endTurn(result: .string("好"), error: nil)
        #expect(turn.map { center.get($0.id)?.status } ?? nil == .completed)
        ctx.dispose()
    }

    @Test("TaskTracking.endTurn 无活跃轮次时空转")
    @ContextTreeActor
    func trackingWithoutTurn() async throws {
        let center = try DefaultTaskCenter(clock: s17FixedClock)
        let tracking = TaskTracking(tasks: center)
        try await tracking.endTurn(result: nil, error: nil)
        #expect(center.all.isEmpty)
        #expect(tracking.currentTurnTaskId == nil)
    }

    @Test("spawn_agent 中间件只拦 spawn_agent，其余工具原样放行")
    @ContextTreeActor
    func middlewarePassesThrough() async throws {
        let center = try DefaultTaskCenter(clock: s17FixedClock)
        let registry = ToolRegistry()
        let tracking = TaskTracking(tasks: center)
        _ = registry.use(tracking.spawnAgentMiddleware)
        try registry.register(EchoTool())
        let result = await registry.call(ToolCall(name: "echo", arguments: ["text": .string("hi")]))
        #expect(!result.failed)
        #expect(center.all.isEmpty)
    }

    @Test("schedule 交付任务：抛错的交付不上抛给调度器之外（错误由调用方处理）")
    @ContextTreeActor
    func scheduleDeliveryTask() async throws {
        let center = try DefaultTaskCenter(clock: s17FixedClock)
        let deliver = trackScheduleDelivery(center) { text in
            text == "提醒"
        }
        #expect(try await deliver("提醒"))
        #expect(try await deliver("别的") == false)
        #expect(center.all.map(\.status) == [.completed, .failed])
        #expect(center.all.map(\.description) == ["提醒: 提醒", "提醒: 别的"])
    }

    @Test("shell 装饰器：追踪失败（中心已释放）时静默让位")
    @ContextTreeActor
    func shellTrackingAfterDispose() async throws {
        let center = try DefaultTaskCenter(clock: s17FixedClock)
        let executor = TrackingTaskShellExecutor(inner: LocalShellExecutor(), tasks: center)
        let process = try await executor.start(executor.resolve(ShellExecRequest(command: "sleep 1")))
        center.dispose()
        _ = process.kill()
        await process.done.value
        // 给追踪任务一点落定时间：它会因中心已释放而失败并被静默吞掉。
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        // dispose 后的落定失败被吞掉：不抛错、任务停在 running。
        #expect(center.all.first?.status == .running)
    }
}

/// 最小 echo 工具（中间件放行验证用）。
@ContextTreeActor
final class EchoTool: Tool {
    let name = "echo"
    let description = "回显"

    let params: [ParamSpec] = [.string("text", description: "文本", required: true)]

    func call(_ context: ToolContext) async throws -> ToolResult {
        .success(try context.requireString("text"))
    }
}
