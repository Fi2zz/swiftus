import SwiftusCore
import SwiftusFoundation

/// `schedule_list`：按创建顺序列出当前会话的活动提醒。
@ContextTreeActor
public final class ScheduleListTool: Tool {
    private let schedule: SessionSchedule

    public init(schedule: SessionSchedule) {
        self.schedule = schedule
    }

    public let name = "schedule_list"

    public let description = "List every active reminder in the current session in creation order, "
        + "including its exact id, UTC target, scheduled or overdue state, and "
        + "session-local delivery mode."

    public let group: String? = "schedule"

    public func call(_ context: ToolContext) async throws -> ToolResult {
        do {
            let views = try await schedule.list()
            return scheduleSuccessResult(.array(views.map(\.jsonValue)))
        } catch {
            return scheduleFailureResult(error)
        }
    }
}

/// `schedule_delete`：按标识删除一条活动提醒。
@ContextTreeActor
public final class ScheduleDeleteTool: Tool {
    private let schedule: SessionSchedule

    public init(schedule: SessionSchedule) {
        self.schedule = schedule
    }

    public let name = "schedule_delete"

    public let description = "Delete one active reminder in the current session by the exact id "
        + "returned by schedule_create or schedule_list. Unknown or already-finished "
        + "ids return deleted false."

    public let riskLevel: ToolRisk = .medium

    public let group: String? = "schedule"

    public let params: [ParamSpec] = [
        .string("id", description: "Exact session-local schedule id.", required: true),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        let id = try context.string("id")
        guard let id, !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return scheduleErrorResult(
                ScheduleErrorCode.invalidRule,
                "schedule_delete id must be non-empty without surrounding whitespace."
            )
        }
        do {
            let result = try await schedule.delete(id)
            return scheduleSuccessResult(result.jsonValue)
        } catch {
            return scheduleFailureResult(error)
        }
    }
}

/// 把三个提醒工具注册到注册表，返回已注册的工具（规格 S8 §11.2）。
///
/// schedule 缺省取上下文的 `schedule` 服务；tools 缺省取 `tools` 服务。
/// 注册经 `ctx.effect` 登记，随上下文释放而撤销。
@ContextTreeActor
@discardableResult
public func provideScheduleTools(
    _ ctx: Context,
    schedule: SessionSchedule? = nil,
    tools: ToolRegistry? = nil
) throws -> [any Tool] {
    guard let resolvedSchedule = schedule ?? ctx.get(.schedule) else {
        throw ContextError.serviceUnavailable(key: "schedule", context: ctx.name)
    }
    let registry = tools ?? ctx.get(.tools)
    guard let registry else {
        throw ContextError.serviceUnavailable(key: "tools", context: ctx.name)
    }
    let registered: [any Tool] = [
        ScheduleCreateTool(schedule: resolvedSchedule),
        ScheduleListTool(schedule: resolvedSchedule),
        ScheduleDeleteTool(schedule: resolvedSchedule),
    ]
    for tool in registered {
        try ctx.effect { try registry.register(tool) }
    }
    return registered
}
