import Foundation
import SwiftusCore

/// 由内部记录与单次墙钟采样构造模型可见视图（规格 S9 §2）。
public func buildCronTaskView(_ task: CronTask, now: Date, startedAt: Date, zone: TimeZone) -> CronTaskView {
    CronTaskView(
        id: task.id,
        prompt: task.prompt,
        schedule: cronScheduleJson(task),
        enabled: task.isEnabled,
        origin: task.origin,
        sessionId: task.sessionId,
        lastRunAt: task.lastRunAt,
        firedAt: task.firedAt,
        nextRunAt: cronNextRunAt(of: task, now: now, startedAt: startedAt, zone: zone)
    )
}

/// 排期规则的四选一对象（规格 S9 §2）。
func cronScheduleJson(_ task: CronTask) -> [String: JSONValue] {
    if let at = task.at { return ["at": .string(at)] }
    if let every = task.every {
        // 整数值不带小数点（与来源 num → JSON 的形状一致）。
        return ["everySeconds": every == every.rounded() ? .int(Int64(every)) : .double(every)]
    }
    if let daily = task.daily { return ["daily": .string(daily)] }
    return ["cron": .string(task.cron ?? "")]
}

/// 触发消息 framing；**逐行固定，不许改写**（规格 S9 §8）。
///
/// 明确告知模型这是自动化任务而非用户输入，是防注入设计的一部分。
public func renderCronTaskMessage(id: String, prompt: String, slot: Date, firedAt: Date) -> String {
    [
        "[cron] Scheduled task \"\(id)\" fired.",
        "Scheduled for: \(CronInstant.format(slot).stringValue ?? "")",
        "Fired at: \(CronInstant.format(firedAt).stringValue ?? "")",
        "",
        "This is an automated task submitted by the cron plugin, "
            + "not a message from the user.",
        "Execute the task inside <task> now, then report the result concisely.",
        "",
        "<task>",
        prompt,
        "</task>",
    ].joined(separator: "\n")
}
