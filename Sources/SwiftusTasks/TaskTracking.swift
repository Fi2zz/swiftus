import Foundation
import SwiftusAgent
import SwiftusCore
import SwiftusFoundation
import SwiftusSchedule

/// `spawn_agent` 工具名（与 sub_agent 一致）。
public let kSpawnAgentToolName = "spawn_agent"

/// 轮次追踪 + `spawn_agent` 中间件的持有者（规格 S17 §5.2）。
///
/// 每个被追踪的会话一个实例：Agent Loop 轮次经 `AgentLoop.turnTracker` 挂载，
/// sub-agent 委托经工具中间件挂载，二者都只依赖 `tasks` 端口。
@ContextTreeActor
public final class TaskTracking: AgentTurnTracker {
    /// 任务中心。
    public let tasks: any TaskCenter

    private let context: Context?
    private var activeTurnTaskId: String?

    /// 构造追踪器；`ctx` 用于惰性解析 `goal` / `planMode` 写入任务 metadata
    ///（可空，缺省不关联）。
    public init(tasks: any TaskCenter, ctx: Context? = nil) {
        self.tasks = tasks
        self.context = ctx
    }

    /// 当前 Agent Turn 的任务 id（无活跃轮次时为 nil）。
    public var currentTurnTaskId: String? {
        activeTurnTaskId
    }

    public func beginTurn(_ userInput: String) async throws {
        var metadata: [String: JSONValue] = [:]
        if let goalId = context?.get(.goal)?.current?.id {
            metadata["goalId"] = .string(goalId)
        }
        if context?.get(.planMode)?.state == .active {
            metadata["planMode"] = .bool(true)
        }
        let task = try await tasks.create(
            kind: .agentTurn,
            description: "处理: \(userInput)",
            metadata: metadata
        )
        activeTurnTaskId = task.id
        try await tasks.update(task.id, status: .running)
    }

    public func endTurn(result: JSONValue?, error: (any Error)?) async throws {
        let id = activeTurnTaskId
        activeTurnTaskId = nil
        guard let id else { return }
        if let error {
            try await tasks.update(id, status: .failed, result: nil, error: taskErrorValue(error))
            return
        }
        try await tasks.update(id, status: .completed, result: result, error: nil)
    }

    /// 拦 `spawn_agent` 调用的中间件：为每次委托创建 subAgent 任务，
    /// 挂在当前轮次任务下；其余工具调用原样放行。
    ///
    /// 子 Agent 的结局从结果值判定（`status == failed`，spawn_agent 会把子
    /// Agent 异常收敛进结果值而非失败结果，规格 S17 §5.2）。
    public var spawnAgentMiddleware: ToolMiddleware {
        { [self] call, next in
            guard call.name == kSpawnAgentToolName else { return try await next() }
            var metadata: [String: JSONValue] = [:]
            if let tools = call.arguments["tools"] {
                metadata["tools"] = tools
            }
            if let maxRounds = call.arguments["max_rounds"] {
                metadata["maxRounds"] = maxRounds
            }
            let task = try await tasks.create(
                kind: .subAgent,
                description: "子 Agent: \(call.arguments["task"]?.stringValue ?? "")",
                parentTaskId: activeTurnTaskId,
                metadata: metadata
            )
            try await tasks.update(task.id, status: .running)
            let result = try await next()
            let value = result.value?.objectValue
            let subFailed = result.failed || value?["status"]?.stringValue == "failed"
            if subFailed {
                // 结果值是对象时取其 output（缺失则不改 error），否则退化为结果文本。
                let failure: JSONValue? = value == nil ? .string(result.content) : value?["output"]
                try await tasks.update(task.id, status: .failed, result: nil, error: failure)
            } else {
                try await tasks.update(task.id, status: .completed, result: result.value)
            }
            return result
        }
    }
}

// ══════════════════════════════════════════════════════════════
// shell 执行追踪（规格 S17 §5.4；执行端口见 S18 §4）
// ══════════════════════════════════════════════════════════════

/// 给 shell 执行器加任务追踪的装饰器：每次前台 / 后台执行建一个 shell 任务，
/// 进程落定时按退出码置 completed / failed。
///
/// 包裹的是 S18 的 `ShellExecutor`（本地后端 / 任意执行器），S17 §7 记录的
/// 「任务域自带 shell 端口」偏离在此收口。
@ContextTreeActor
public final class TrackingTaskShellExecutor: ShellExecutor {
    /// 被包装的执行器。
    public let inner: any ShellExecutor
    /// 任务中心。
    public let tasks: any TaskCenter

    public init(inner: any ShellExecutor, tasks: any TaskCenter) {
        self.inner = inner
        self.tasks = tasks
    }

    public func resolve(_ request: ShellExecRequest) -> ShellExecSpec {
        inner.resolve(request)
    }

    public func run(_ spec: ShellExecSpec) async throws -> ShellRunResult {
        let task = try await begin(spec)
        let result = try await inner.run(spec)
        try await finish(task.id, exitCode: result.exitCode)
        return result
    }

    public func start(_ spec: ShellExecSpec) async throws -> any ShellProcess {
        let task = try await begin(spec)
        let process = try await inner.start(spec)
        track(task.id, process)
        return process
    }

    private func begin(_ spec: ShellExecSpec) async throws -> Task {
        let task = try await tasks.create(
            kind: .shell,
            description: "Shell: \(spec.command)",
            metadata: ["command": .string(spec.command)]
        )
        try await tasks.update(task.id, status: .running, result: nil, error: nil)
        return task
    }

    /// 后台进程结束落定；追踪失败（中心已释放或任务已终态）时静默让位给
    /// 执行结果本身（规格 S17 §5.4）。
    private func track(_ id: String, _ process: any ShellProcess) {
        let center = tasks
        // 本 target 另有 Task 值类型，闭包任务需写全 _Concurrency.Task。
        _Concurrency.Task<Void, Never> { [center] in
            // done 落定后 exitCode 已是终值（同一 actor 上同步可读），不再 await。
            await process.done.value
            let exitCode = process.exitCode
            _ = try? await center.update(
                id,
                status: exitCode == 0 ? .completed : .failed,
                result: .object(["exitCode": exitCode.map { JSONValue.int(Int64($0)) } ?? .null]),
                error: nil
            )
        }
    }

    private func finish(_ id: String, exitCode: Int?) async throws {
        let result: JSONValue = .object([
            "exitCode": exitCode.map { JSONValue.int(Int64($0)) } ?? .null,
        ])
        try await tasks.update(
            id,
            status: exitCode == 0 ? .completed : .failed,
            result: result,
            error: nil
        )
    }
}

// ══════════════════════════════════════════════════════════════
// schedule 交付追踪（规格 S17 §5.3）
// ══════════════════════════════════════════════════════════════

/// 包装提醒交付：每次交付建一个 schedule 任务，按交付结果落定。
///
/// 直接适配 `provideScheduleRuntime` 的 `deliver` 参数；cron 的两参交付
/// 在装配方处自行适配后调用。
@ContextTreeActor
public func trackScheduleDelivery(
    _ tasks: any TaskCenter,
    _ deliver: @escaping ScheduleDelivery
) -> ScheduleDelivery {
    { [tasks] text in
        let task = try await tasks.create(kind: .schedule, description: "提醒: \(text)")
        try await tasks.update(task.id, status: .running)
        let delivered = try await deliver(text)
        try await tasks.update(task.id, status: delivered ? .completed : .failed)
        return delivered
    }
}
