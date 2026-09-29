import Foundation
import SwiftusCore

/// cron 任务服务；服务键 `cron`（规格 S9 §6 / §7）。
///
/// 服务是任务表与运行历史的权威状态：任务侧委托 `CronTaskRegistry`、历史侧
/// 委托 `CronHistoryBook`，自身只保留共享操作与交付收尾。**墙钟与时区都注入**
/// （`clock` / `timeZone`），模块不直读系统时钟也不读系统时区——fixtures 固定
/// UTC，生产用当前时区。
@ContextTreeActor
public final class CronService {
    /// 告警回调；`CronRuntime` 缺省复用同一通道。
    public let onWarning: (@Sendable (String) -> Void)?

    /// 服务装配时刻；`every` / `cron` 从未运行的任务以它为锚点。
    public let startedAt: Date

    /// 规则语义使用的本地时区。
    public let timeZone: TimeZone

    private let clock: @Sendable () -> Date
    private let registry: CronTaskRegistry
    private let book: CronHistoryBook

    /// 构造并装配服务：`storage` 的持久状态 + `configTasks` 叠加。
    ///
    /// `entropy` 是 id 随机后缀的熵源（测试注入定值；生产用系统随机）。
    public init(
        storage: any CronStorage,
        configTasks: [[String: JSONValue]] = [],
        timeZone: TimeZone = .current,
        clock: @escaping @Sendable () -> Date = Date.init,
        onWarning: (@Sendable (String) -> Void)? = nil,
        entropy: @escaping @Sendable (Int) -> Int = { space in
            Int.random(in: 0..<space)
        }
    ) {
        self.clock = clock
        self.onWarning = onWarning
        self.timeZone = timeZone
        startedAt = clock()
        registry = CronTaskRegistry(
            storage: storage,
            now: clock,
            onWarning: onWarning,
            entropy: entropy
        )
        book = CronHistoryBook(storage: storage, now: clock)
        registry.boot(configTasks: configTasks)
    }

    /// 采样当前墙钟。
    public func now() -> Date {
        clock()
    }

    /// 全部任务内部记录（配置 + 动态，登记序）。
    public var tasks: [CronTask] {
        registry.tasks
    }

    /// 按 id 找任务；不存在返回 nil（运行时投递用）。
    public func findTask(_ id: String) -> CronTask? {
        registry.findTask(id)
    }

    /// 列出全部任务的模型可见视图（按当前墙钟）。
    public func listTasks() -> [CronTaskView] {
        let now = clock()
        return registry.tasks.map { buildCronTaskView($0, now: now, startedAt: startedAt, zone: timeZone) }
    }

    /// 单个任务的模型可见视图（按当前墙钟）。
    public func taskView(_ task: CronTask) -> CronTaskView {
        buildCronTaskView(task, now: clock(), startedAt: startedAt, zone: timeZone)
    }

    /// 添加动态任务；`input` 形状与来源一致（id 缺省生成，会话绑定缺省取调用方）。
    public func addDynamicTask(
        _ input: [String: JSONValue],
        callerSessionId: String? = nil
    ) throws -> CronTaskView {
        let task = try registry.addDynamic(input, callerSessionId: callerSessionId)
        return taskView(task)
    }

    /// 编辑动态任务；patch 含任何规则键则整组规则替换并重置运行戳（规格 S9 §6）。
    public func updateDynamicTask(_ id: String, _ patch: [String: JSONValue]) throws -> CronTaskView {
        let task = try registry.requireDynamicTask(id, "edit")
        let prompt = cronResolvePrompt(task.prompt, patch["prompt"])
        let touched = cronPatchTouchesSchedule(patch)
        let merged = cronMergeRules(task, prompt: prompt, touched: touched, patch)
        if let invalid = validateCronTaskInput(CronTaskInput(
            id: .string(id),
            prompt: .string(prompt),
            at: merged["at"],
            every: merged["every"],
            daily: merged["daily"],
            cron: merged["cron"]
        )) {
            throw CronException(.invalidTask, invalid)
        }
        cronApplyRules(task, merged)
        if touched { cronResetRunState(task) }
        registry.save()
        return taskView(task)
    }

    /// 删除动态任务；配置任务抛 `config-task`，不存在抛 `not-found`。
    public func removeDynamicTask(_ id: String) throws {
        _ = try registry.requireDynamicTask(id, "remove")
        registry.removeTask(id)
    }

    /// 设置启停覆盖；与声明值一致时覆盖归空（回到声明值）。
    public func setEnabled(_ id: String, _ enabled: Bool) throws -> CronTaskView {
        let task = try registry.requireTask(id)
        task.enabledOverride = enabled == task.enabled ? nil : enabled
        registry.save()
        return taskView(task)
    }

    /// 最新在前的运行历史；`limit` 非法退化为 100，封顶 `kCronMaxHistory`。
    public func listHistory(limit: Int? = nil) -> [CronRunRecord] {
        book.list(limit: limit)
    }

    /// 推进一条运行记录到终态（`completed` / `failed`）；不存在返回 nil。
    public func finishRun(_ recordId: String, ok: Bool, excerpt: String? = nil) -> CronRunRecord? {
        book.finish(recordId, ok: ok, excerpt: excerpt)
    }

    /// 预分配运行记录标识（交付端口以 id 关联 `finishRun`）。
    public func allocateRecordRef(_ now: Date) -> CronRecordRef {
        book.allocateRef(now: now)
    }

    /// 交付被拒时归还标识，保持 seq 连续。
    public func releaseRecordRef(_ ref: CronRecordRef) {
        book.release(ref)
    }

    /// 交付成功后收尾：更新运行戳、落盘、追加 `delivered` 记录（规格 S9 §8）。
    public func commitFire(
        ref: CronRecordRef,
        taskId: String,
        slot: Date,
        firedAt: Date
    ) -> CronRunRecord {
        let task = registry.findTask(taskId)
        if let task {
            task.lastRunAt = firedAt
            if task.at != nil { task.firedAt = firedAt }
            // cron 缓存失效，下个 tick 重算下一触发分钟。
            task.cronNext = nil
        }
        registry.save()
        return book.append(CronRunRecord(
            id: ref.id,
            seq: ref.seq,
            taskId: taskId,
            prompt: task?.prompt ?? "",
            sessionId: task?.sessionId,
            scheduledFor: slot,
            firedAt: firedAt,
            status: .delivered
        ))
    }
}

/// 'cron' 服务键。
extension ServiceKey where Service == CronService {
    public static let cron = ServiceKey<CronService>("cron")
}

// MARK: - 编辑规则（patch 合并、规则替换与运行戳重置）

/// patch 是否触碰任何调度规则键（值非 nil 即算触碰）。
func cronPatchTouchesSchedule(_ patch: [String: JSONValue]) -> Bool {
    kCronRuleKeys.contains { patch[$0] != nil }
}

/// 任务在某个规则键下的当前值。
private func cronRuleValue(_ task: CronTask, _ key: String) -> JSONValue? {
    switch key {
    case "at": return task.at.map { .string($0) }
    case "every": return task.every.map { .double($0) }
    case "daily": return task.daily.map { .string($0) }
    default: return task.cron.map { .string($0) }
    }
}

/// 合并编辑补丁：触碰规则时整组替换为 patch 里的规则，否则保留原规则。
func cronMergeRules(
    _ task: CronTask,
    prompt: String,
    touched: Bool,
    _ patch: [String: JSONValue]
) -> [String: JSONValue] {
    var merged: [String: JSONValue] = ["id": .string(task.id), "prompt": .string(prompt)]
    for key in kCronRuleKeys {
        let value = touched ? patch[key] : cronRuleValue(task, key)
        if let value { merged[key] = value }
    }
    return merged
}

/// 把校验后的合并结果写回任务记录。
func cronApplyRules(_ task: CronTask, _ merged: [String: JSONValue]) {
    task.prompt = merged["prompt"]?.stringValue ?? ""
    task.at = merged["at"]?.stringValue
    task.every = cronNumber(merged["every"])
    task.daily = merged["daily"]?.stringValue
    task.cron = merged["cron"]?.stringValue
}

/// 规则被替换后重置运行状态，让新规则立即生效。
func cronResetRunState(_ task: CronTask) {
    task.lastRunAt = nil
    task.firedAt = nil
    task.cronNext = nil
    task.cronParsed = task.cron.flatMap { parseCronExpression($0) }
}

/// 解析 update 的 prompt 补丁：非空字符串胜出，否则保留现状。
func cronResolvePrompt(_ current: String, _ patch: JSONValue?) -> String {
    guard case .some(.string(let text)) = patch else { return current }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? current : trimmed
}
