/// 任务中心：运行时的任务追踪中枢（规格 S17）。
///
/// Task Center 只回答「现在有哪些任务在跑、各自什么状态、能不能取消」，
/// 不负责调度与执行。任务由 Agent Loop / sub-agent / shell / schedule 经
/// `TaskTracking` 装饰器自动创建（`parentTaskId` 组成任务树），状态以
/// `task/changed` 事件持久化到会话（整值替换，恢复时未完成任务标记为 failed），
/// 模型侧只有 `list_tasks` / `cancel_task` 两个工具。
///
/// ```swift
/// let tasks = try provideTaskCenter(ctx)
/// try provideTaskTracking(ctx)        // 挂 Agent Loop 轮次钩子 + spawn_agent 追踪
/// let result = await ctx.require(.tools).call(ToolCall(name: kListTasksToolName))
/// ```
