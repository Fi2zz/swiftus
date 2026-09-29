import Foundation
import SwiftusCore

/// id 索引的 cron 任务表（配置 + 动态，规格 S9 §6）。
///
/// 启动顺序与来源一致：持久化动态任务 → 配置静态任务 → 运行戳 → 启停覆盖；
/// config 任务登记后不可增删改；**保存只写显式字段表**，内部缓存永不落盘。
@ContextTreeActor
final class CronTaskRegistry {
    private let storage: any CronStorage
    private let now: @Sendable () -> Date
    private let onWarning: (@Sendable (String) -> Void)?
    /// id → 任务（保持插入序，供视图与遍历稳定）。
    private var table: [(id: String, task: CronTask)] = []
    private var index: [String: Int] = [:]
    private var entropy: (Int) -> Int

    init(
        storage: any CronStorage,
        now: @escaping @Sendable () -> Date,
        onWarning: (@Sendable (String) -> Void)? = nil,
        entropy: @escaping @Sendable (Int) -> Int
    ) {
        self.storage = storage
        self.now = now
        self.onWarning = onWarning
        self.entropy = entropy
    }

    /// 全部任务内部记录（登记序）。
    var tasks: [CronTask] {
        table.map(\.task)
    }

    /// 按 id 找任务；不存在返回 nil。
    func findTask(_ id: String) -> CronTask? {
        guard let position = index[id] else { return nil }
        return table[position].task
    }

    /// 装配：加载持久化动态任务，叠加配置任务，再恢复运行戳与启停覆盖。
    func boot(configTasks: [[String: JSONValue]]) {
        let stored = storage.loadTasks()
        for raw in stored.dynamicTasks {
            tryAdd(raw, origin: .dynamic, source: "stored task")
        }
        for raw in configTasks {
            tryAdd(raw, origin: .config, source: "config task")
        }
        for (id, stamp) in stored.runStamps {
            guard let task = findTask(id) else { continue }
            task.lastRunAt = stamp.lastRunAt
            task.firedAt = stamp.firedAt
        }
        for (id, flag) in stored.overrides {
            findTask(id)?.enabledOverride = flag
        }
    }

    /// 登记一个动态任务（已归一化 id / 会话绑定），随后落盘。
    func addDynamic(_ input: [String: JSONValue], callerSessionId: String?) throws -> CronTask {
        var normalized = input
        if isBlank(normalized["id"]) {
            normalized["id"] = .string(try allocateTaskId())
        }
        if isBlank(normalized["sessionId"]) {
            normalized["sessionId"] = callerSessionId.map { JSONValue.string($0) }
        }
        let task = try addFromRaw(normalized, origin: .dynamic)
        save()
        return task
    }

    /// 校验并登记一条任务原文；非法输入抛 `invalid-task`，重 id 抛 `duplicate-id`。
    @discardableResult
    func addFromRaw(_ raw: [String: JSONValue], origin: CronTaskOrigin) throws -> CronTask {
        if let invalid = validateCronTaskInput(CronTaskInput(raw)) {
            throw CronException(.invalidTask, invalid)
        }
        let id = raw["id"]?.stringValue ?? ""
        guard index[id] == nil else {
            throw CronException(.duplicateId, "task \"\(id)\" already exists")
        }
        let task = CronTask(
            id: id,
            prompt: raw["prompt"]?.stringValue ?? "",
            at: raw["at"]?.stringValue,
            every: cronNumber(raw["every"]),
            daily: raw["daily"]?.stringValue,
            cron: raw["cron"]?.stringValue,
            sessionId: raw["sessionId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            // 创建时 `enabled` 缺省为真，只有显式 false 才为假。
            enabled: { if case .bool(false) = raw["enabled"] { return false }; return true }(),
            origin: origin
        )
        if let cron = task.cron {
            task.cronParsed = parseCronExpression(cron)
        }
        insert(task)
        return task
    }

    /// 生成并占用一个唯一任务 id（最多试 100 次避免撞 id）。
    func allocateTaskId() throws -> String {
        let now = self.now()
        let space = 36 * 36 * 36 * 36
        for _ in 0..<100 {
            let id = generateCronTaskId(now: now, randomSuffix: entropy(space))
            if index[id] == nil { return id }
        }
        throw CronException(.invalidTask, "could not allocate a task id")
    }

    /// 按 id 取任务；不存在抛 `not-found`。
    func requireTask(_ id: String) throws -> CronTask {
        guard let task = findTask(id) else {
            throw CronException(.notFound, "no task with id \"\(id)\"")
        }
        return task
    }

    /// 按 id 取动态任务；配置任务抛 `config-task`。
    func requireDynamicTask(_ id: String, _ verb: String) throws -> CronTask {
        let task = try requireTask(id)
        guard task.origin == .dynamic else {
            throw CronException(.configTask, "task \"\(id)\" comes from config; \(verb) it there")
        }
        return task
    }

    /// 删除任务并落盘。
    func removeTask(_ id: String) {
        if let position = index[id] {
            table.remove(at: position)
            rebuildIndex()
        }
        save()
    }

    /// 按显式字段表落盘（动态任务 + 运行戳 + 启停覆盖）。
    func save() {
        storage.saveTasks(
            tasks: table.map(\.task).filter { $0.origin == .dynamic }.map(encodeTask),
            runStamps: stampTable(table),
            overrides: overrideTable(table)
        )
    }

    private func tryAdd(_ raw: [String: JSONValue], origin: CronTaskOrigin, source: String) {
        do {
            _ = try addFromRaw(raw, origin: origin)
        } catch let error as CronException {
            onWarning?("cron: skipping \(source): \(error.message)")
        } catch {
            onWarning?("cron: skipping \(source): \(error)")
        }
    }

    private func insert(_ task: CronTask) {
        index[task.id] = table.count
        table.append((id: task.id, task: task))
    }

    private func rebuildIndex() {
        index = [:]
        for (position, entry) in table.enumerated() {
            index[entry.id] = position
        }
    }

    private func isBlank(_ value: JSONValue?) -> Bool {
        switch value {
        case .none, .some(.null): return true
        case .some(.string(let text)): return text.isEmpty
        default: return false
        }
    }
}

/// 显式字段表：内部缓存（解析结果 / 下一分钟）永不落盘（规格 S9 §6）。
private func encodeTask(_ task: CronTask) -> [String: JSONValue] {
    var raw: [String: JSONValue] = [
        "id": .string(task.id),
        "prompt": .string(task.prompt),
        "sessionId": task.sessionId.map { .string($0) } ?? .null,
        "enabled": .bool(task.enabled),
    ]
    if let at = task.at { raw["at"] = .string(at) }
    if let every = task.every {
        raw["every"] = every == every.rounded() ? .int(Int64(every)) : .double(every)
    }
    if let daily = task.daily { raw["daily"] = .string(daily) }
    if let cron = task.cron { raw["cron"] = .string(cron) }
    return raw
}

private func stampTable(_ table: [(id: String, task: CronTask)]) -> [String: CronRunStamp] {
    var stamps: [String: CronRunStamp] = [:]
    for entry in table {
        let task = entry.task
        if task.lastRunAt != nil || task.firedAt != nil {
            stamps[task.id] = CronRunStamp(lastRunAt: task.lastRunAt, firedAt: task.firedAt)
        }
    }
    return stamps
}

private func overrideTable(_ table: [(id: String, task: CronTask)]) -> [String: Bool] {
    var flags: [String: Bool] = [:]
    for entry in table {
        if let flag = entry.task.enabledOverride { flags[entry.task.id] = flag }
    }
    return flags
}
