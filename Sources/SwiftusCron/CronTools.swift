import Foundation
import SwiftusCore
import SwiftusFoundation

// MARK: - 结果形状

/// 成功结果：规范值同时作为文本与结构化值返回。
func cronSuccessResult(_ value: JSONValue) -> ToolResult {
    let text = (try? value.jsonData()).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    return .success(text, value: value)
}

/// 失败结果：文本是 `{code, message}` 的 JSON，错误码透传给宿主。
func cronErrorResult(_ code: CronErrorCode, _ message: String) -> ToolResult {
    cronErrorResult(code.rawValue, message)
}

/// 失败结果（原始错误码串，便于映射来源之外的码）。
func cronErrorResult(_ code: String, _ message: String) -> ToolResult {
    let payload = JSONValue.object(["code": .string(code), "message": .string(message)])
    let text = (try? payload.jsonData()).map { String(decoding: $0, as: UTF8.self) } ?? code
    return .failure(text, error: ToolError(code, message))
}

/// 不暴露内部细节的兜底失败结果。
func cronInternalResult() -> ToolResult {
    cronErrorResult(.internalError, "The cron operation failed.")
}

/// 异常 → 失败结果映射：`CronException` 透传码与消息，其余兜底（规格 S9 §10）。
func cronFailureResult(_ error: any Error) -> ToolResult {
    if let cron = error as? CronException {
        return cronErrorResult(cron.code, cron.message)
    }
    return cronInternalResult()
}

// MARK: - 只读工具

/// `cron_list`：列出全部定时任务（配置 + 动态）及其状态与下次触发时刻。
@ContextTreeActor
public final class CronListTool: Tool {
    private let service: CronService

    public init(service: CronService) {
        self.service = service
    }

    public let name = "cron_list"

    public let description = "List all scheduled tasks (from config and added at runtime) with "
        + "their state and next run time."

    public let group: String? = "cron"

    public func call(_ context: ToolContext) async throws -> ToolResult {
        // 列视图为纯读（到期判定是纯函数且不抛），故此处无需失败映射。
        cronSuccessResult(.array(service.listTasks().map { .object($0.json) }))
    }
}

/// `cron_history`：查看最近的任务执行记录（最新在前）。
@ContextTreeActor
public final class CronHistoryTool: Tool {
    private let service: CronService

    public init(service: CronService) {
        self.service = service
    }

    public let name = "cron_history"

    public let description = "Show recent scheduled-task execution records: when each task fired, "
        + "whether it completed, and a short result excerpt."

    public let group: String? = "cron"

    public let params: [ParamSpec] = [
        .integer("limit", description: "Max records to return (default 20, newest first)."),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        do {
            let records = service.listHistory(limit: try context.integer("limit") ?? 20)
            return cronSuccessResult(.array(records.map { .object($0.json) }))
        } catch {
            return cronFailureResult(error)
        }
    }
}

// MARK: - 管理工具

/// `cron_add`：添加定时任务；四选一规则，id 缺省自动生成。
@ContextTreeActor
public final class CronAddTool: Tool {
    private let service: CronService
    private let callerSessionId: String?

    public init(service: CronService, callerSessionId: String? = nil) {
        self.service = service
        self.callerSessionId = callerSessionId
    }

    public let name = "cron_add"

    public let description = "Add a scheduled task. Set exactly one rule: at (ISO instant, one-shot), "
        + "every (interval seconds, min \(kCronMinEverySeconds)), daily (\"HH:MM\" local time), or cron "
        + "(standard 5-field expression \"minute hour day month weekday\", local time "
        + "— e.g. \"0 9 * * *\" = daily 09:00, \"*/30 * * * *\" = every 30 min, "
        + "\"0 9 * * 1\" = Mondays 09:00). Convert the user's natural-language schedule "
        + "into one of these rules. The task prompt is delivered to the agent "
        + "automatically when due and the result is replied in the conversation. "
        + "Dynamic tasks persist across restarts."

    public let riskLevel: ToolRisk = .medium

    public let group: String? = "cron"

    public let params: [ParamSpec] = [
        .string("id", description: "Optional unique task id (letters, digits, -, _). "
            + "One is generated when omitted."),
        .string("prompt", description: "What the agent should do when the task fires.", required: true),
        .string("at", description: "ISO 8601 instant for a one-shot task."),
        .number("every", description: "Fixed interval in seconds (min \(kCronMinEverySeconds))."),
        .string("daily", description: "Local wall-clock \"HH:MM\" for a daily task."),
        .string("cron", description: "Standard 5-field cron expression "
            + "(minute hour day month weekday), local time."),
        .string("session_id", description: "Bind the task to one session id: runs are delivered there."),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        do {
            let view = try service.addDynamicTask(
                try cronToolTaskInput(context),
                callerSessionId: context.string("_session_id") ?? callerSessionId
            )
            return cronSuccessResult(.object(view.json))
        } catch {
            return cronFailureResult(error)
        }
    }

    /// 模型侧的 `session_id` 参数映射为服务输入的 `sessionId`（显式值优先）。
    private func cronToolTaskInput(_ context: ToolContext) throws -> [String: JSONValue] {
        var input = context.arguments
        input.removeValue(forKey: "session_id")
        if let sessionId = try context.string("session_id") {
            input["sessionId"] = .string(sessionId)
        }
        return input
    }
}

/// `cron_update`：编辑动态任务的 prompt 或整组替换排期规则。
@ContextTreeActor
public final class CronUpdateTool: Tool {
    private let service: CronService

    public init(service: CronService) {
        self.service = service
    }

    public let name = "cron_update"

    public let description = "Edit a dynamically added scheduled task: change its prompt and/or "
        + "replace its schedule rule. Pass exactly one rule (at / every / daily / "
        + "cron) to change the schedule; omitted fields stay unchanged. Tasks "
        + "declared in host config cannot be edited at runtime."

    public let riskLevel: ToolRisk = .medium

    public let group: String? = "cron"

    public let params: [ParamSpec] = [
        .string("id", description: "Id of the task to edit.", required: true),
        .string("prompt", description: "New task prompt."),
        .string("at", description: "Replace the schedule with a one-shot ISO 8601 instant."),
        .number("every", description: "Replace the schedule with a fixed interval in seconds "
            + "(min \(kCronMinEverySeconds))."),
        .string("daily", description: "Replace the schedule with a daily local \"HH:MM\"."),
        .string("cron", description: "Replace the schedule with a standard 5-field cron expression."),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        guard let id = try context.string("id"), !id.isEmpty else {
            return cronErrorResult(.invalidTask, "cron_update id must be non-empty.")
        }
        do {
            let view = try service.updateDynamicTask(id, context.arguments)
            return cronSuccessResult(.object(view.json))
        } catch {
            return cronFailureResult(error)
        }
    }
}

/// `cron_remove`：按 id 删除动态任务；配置任务拒绝删除。
@ContextTreeActor
public final class CronRemoveTool: Tool {
    private let service: CronService

    public init(service: CronService) {
        self.service = service
    }

    public let name = "cron_remove"

    public let description = "Remove a dynamically added scheduled task by id. Tasks declared in host "
        + "config cannot be removed at runtime."

    public let riskLevel: ToolRisk = .medium

    public let group: String? = "cron"

    public let params: [ParamSpec] = [
        .string("id", description: "Id of the task to remove.", required: true),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        guard let id = try context.string("id"), !id.isEmpty else {
            return cronErrorResult(.invalidTask, "cron_remove id must be non-empty.")
        }
        do {
            try service.removeDynamicTask(id)
            return cronSuccessResult(.object(["removed": .string(id)]))
        } catch {
            return cronFailureResult(error)
        }
    }
}

// MARK: - 装配

/// 把五个 cron 工具注册到 `ctx.tools`，返回已注册的工具（规格 S9 §10）。
///
/// `service` 缺省取上下文的 `cron` 服务；注册经 `ctx.effect` 登记，随上下文释放而撤销。
@ContextTreeActor
@discardableResult
public func provideCronTools(
    _ ctx: Context,
    service: CronService? = nil,
    tools: ToolRegistry? = nil,
    callerSessionId: String? = nil
) throws -> [any Tool] {
    guard let resolved = service ?? ctx.get(.cron) else {
        throw ContextError.serviceUnavailable(key: "cron", context: ctx.name)
    }
    let registry = tools ?? ctx.get(.tools)
    guard let registry else {
        throw ContextError.serviceUnavailable(key: "tools", context: ctx.name)
    }
    let registered: [any Tool] = [
        CronListTool(service: resolved),
        CronHistoryTool(service: resolved),
        CronAddTool(service: resolved, callerSessionId: callerSessionId),
        CronUpdateTool(service: resolved),
        CronRemoveTool(service: resolved),
    ]
    for tool in registered {
        try ctx.effect { try registry.register(tool) }
    }
    return registered
}

/// 把 `CronService` 作为 `cron` 服务提供到上下文（规格 S9 §6）。
@ContextTreeActor
@discardableResult
public func provideCron(
    _ ctx: Context,
    storage: any CronStorage,
    configTasks: [[String: JSONValue]] = [],
    timeZone: TimeZone = .current,
    clock: @escaping @Sendable () -> Date = Date.init,
    onWarning: (@Sendable (String) -> Void)? = nil,
    entropy: @escaping @Sendable (Int) -> Int = { space in Int.random(in: 0..<space) }
) throws -> CronService {
    let service = CronService(
        storage: storage,
        configTasks: configTasks,
        timeZone: timeZone,
        clock: clock,
        onWarning: onWarning,
        entropy: entropy
    )
    try ctx.provide(.cron, service)
    return service
}
