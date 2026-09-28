import Foundation
import SwiftusCore
import SwiftusFoundation

/// `list_tasks` 工具名。
public let kListTasksToolName = "list_tasks"
/// `cancel_task` 工具名。
public let kCancelTasksToolName = "cancel_task"

/// 把任务列表格式化为口语化播报文本（语音场景，规格 S17 §4）。
public func describeTasks(_ tasks: [Task], now: Date = Date()) -> String {
    guard !tasks.isEmpty else { return "现在没有任务。" }
    var text = "现在共 \(tasks.count) 个任务："
    for (index, task) in tasks.enumerated() {
        text += "\n\(index + 1). \(task.description)（\(task.status.spokenText)"
        if let duration = task.duration(now: now) {
            text += "，已运行 \(taskDurationText(duration))"
        }
        text += "）"
    }
    return text
}

/// 时长文案：整分钟数 ≥ 1 记分钟，否则记秒（规格 S17 §4）。
private func taskDurationText(_ duration: TimeInterval) -> String {
    let minutes = Int(duration) / 60
    if minutes >= 1 { return "\(minutes) 分钟" }
    return "\(Int(duration)) 秒"
}

/// 任务相关错误 → 失败结果（规格 S17 §4）。
private func taskFailure(_ error: TaskError) -> ToolResult {
    .failure(error.message, error: ToolError(error.code, error.message))
}

/// 列出当前任务。可按状态、类型、父任务过滤（low）。
@ContextTreeActor
public final class ListTasksTool: Tool {
    private let taskCenter: any TaskCenter

    public init(taskCenter: any TaskCenter) {
        self.taskCenter = taskCenter
    }

    public let name = kListTasksToolName
    public let description = "列出当前任务。可按状态、类型、父任务过滤。"

    public let params: [ParamSpec] = [
        .enumeration("status", [
            "pending", "running", "paused", "completed", "failed", "cancelled",
        ], description: "按状态过滤"),
        .enumeration("kind", [
            "agentTurn", "subAgent", "shell", "schedule", "custom",
        ], description: "按类型过滤"),
        .string("parent_id", description: "按父任务过滤"),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        var tasks = taskCenter.all
        if let status = try context.string("status") {
            tasks = tasks.filter { $0.status.rawValue == status }
        }
        if let kind = try context.string("kind") {
            tasks = tasks.filter { $0.kind.rawValue == kind }
        }
        if let parentId = try context.string("parent_id") {
            tasks = tasks.filter { $0.parentTaskId == parentId }
        }
        return .success(describeTasks(tasks))
    }
}

/// 取消一个任务，会同时取消其所有子任务（medium；shell 类任务走 approval 确认）。
@ContextTreeActor
public final class CancelTaskTool: Tool {
    private let taskCenter: any TaskCenter

    public init(taskCenter: any TaskCenter) {
        self.taskCenter = taskCenter
    }

    public let name = kCancelTasksToolName
    public let description = "取消一个任务，会同时取消其所有子任务。"

    public let riskLevel: ToolRisk = .medium

    public let params: [ParamSpec] = [
        .string("id", description: "任务 ID", required: true),
    ]

    public func call(_ context: ToolContext) async throws -> ToolResult {
        do {
            let id = try context.requireString("id")
            try await taskCenter.cancel(id)
            let task = taskCenter.get(id)
            return .success("好的，已取消任务「\(task?.description ?? id)」。")
        } catch let error as TaskError {
            return taskFailure(error)
        }
    }
}
