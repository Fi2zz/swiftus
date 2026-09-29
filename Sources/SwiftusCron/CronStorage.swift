import Foundation
import SwiftusCore
import SwiftusFoundation

/// 启动时从存储恢复的运行戳（规格 S9 §9）。
public struct CronRunStamp: Sendable, Equatable {
    public let lastRunAt: Date?
    public let firedAt: Date?

    public init(lastRunAt: Date? = nil, firedAt: Date? = nil) {
        self.lastRunAt = lastRunAt
        self.firedAt = firedAt
    }
}

/// 任务存储的快照：动态任务原文 + 运行戳 + 启停覆盖。
public struct CronStorageSnapshot: Sendable, Equatable {
    public let dynamicTasks: [[String: JSONValue]]
    public let runStamps: [String: CronRunStamp]
    public let overrides: [String: Bool]

    public init(
        dynamicTasks: [[String: JSONValue]] = [],
        runStamps: [String: CronRunStamp] = [:],
        overrides: [String: Bool] = [:]
    ) {
        self.dynamicTasks = dynamicTasks
        self.runStamps = runStamps
        self.overrides = overrides
    }

    public static let empty = CronStorageSnapshot()
}

/// cron 任务与运行历史的存储端口（规格 S9 §9）。
///
/// 与 `FileSystem` / `ShellExecutor` 同构的能力缝：读取**宽容降级**（缺失视为空、
/// 损坏告警后视为空），**写入失败不抛**（调度不该因存储故障中断）。
@ContextTreeActor
public protocol CronStorage: AnyObject, Sendable {
    /// 加载任务快照。
    func loadTasks() -> CronStorageSnapshot
    /// 保存任务快照（只传显式字段表）。
    func saveTasks(
        tasks: [[String: JSONValue]],
        runStamps: [String: CronRunStamp],
        overrides: [String: Bool]
    )
    /// 加载运行历史（旧记录在前，原始 JSON 对象；撕裂行由实现跳过）。
    func loadHistory() -> [JSONValue]
    /// 完整重写运行历史。
    func saveHistory(_ records: [JSONValue])
}

/// 本地 JSON / JSONL 存储（规格 S9 §9）。
///
/// 任务表一个 JSON 文件、历史一个 JSONL 文件；写入经临时文件 + rename 原子发布。
@ContextTreeActor
public final class JsonCronStorage: CronStorage {
    public let tasksPath: String
    public let historyPath: String
    private let onWarning: (@Sendable (String) -> Void)?

    public init(
        tasksPath: String,
        historyPath: String,
        onWarning: (@Sendable (String) -> Void)? = nil
    ) {
        self.tasksPath = tasksPath
        self.historyPath = historyPath
        self.onWarning = onWarning
    }

    public func loadTasks() -> CronStorageSnapshot {
        let manager = FileManager.default
        guard manager.fileExists(atPath: tasksPath),
              let data = manager.contents(atPath: tasksPath),
              let json = try? JSONValue.parse(data),
              let object = json.objectValue else {
            return .empty
        }
        let tasks = (object["tasks"]?.arrayValue ?? []).compactMap(\.objectValue)
        var runStamps: [String: CronRunStamp] = [:]
        for (id, value) in object["runStamps"]?.objectValue ?? [:] {
            runStamps[id] = CronRunStamp(
                lastRunAt: value["lastRunAt"]?.stringValue.flatMap(CronInstant.parse),
                firedAt: value["firedAt"]?.stringValue.flatMap(CronInstant.parse)
            )
        }
        var overrides: [String: Bool] = [:]
        for (id, value) in object["overrides"]?.objectValue ?? [:] {
            if case .bool(let flag) = value { overrides[id] = flag }
        }
        return CronStorageSnapshot(dynamicTasks: tasks, runStamps: runStamps, overrides: overrides)
    }

    public func saveTasks(
        tasks: [[String: JSONValue]],
        runStamps: [String: CronRunStamp],
        overrides: [String: Bool]
    ) {
        var stamps: [String: JSONValue] = [:]
        for (id, stamp) in runStamps {
            stamps[id] = .object([
                "lastRunAt": CronInstant.format(stamp.lastRunAt),
                "firedAt": CronInstant.format(stamp.firedAt),
            ])
        }
        var flags: [String: JSONValue] = [:]
        for (id, flag) in overrides { flags[id] = .bool(flag) }
        let payload = JSONValue.object([
            "version": .int(Int64(kCronStorageVersion)),
            "tasks": .array(tasks.map { .object($0) }),
            "runStamps": .object(stamps),
            "overrides": .object(flags),
        ])
        // 写入失败只告警，不抛（规格 S9 §9）。
        if let data = try? payload.jsonData() {
            writeAtomically(data, to: tasksPath)
        } else {
            onWarning?("cron: 任务表编码失败，跳过写入 \(tasksPath)")
        }
    }

    public func loadHistory() -> [JSONValue] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: historyPath),
              let text = try? String(contentsOfFile: historyPath, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").compactMap { line in
            try? JSONValue.parse(Data(line.utf8))
        }
    }

    public func saveHistory(_ records: [JSONValue]) {
        // JSONL 是「每行一个 JSON 值」，整份文件**不是**一个 JSON 文档——
        // 因此这里拼字节直写，不能拿 JSONValue 包一层（顶层标量 JSONSerialization 会抛）。
        let text = records
            .compactMap { try? $0.jsonData() }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
        writeAtomically(Data((text.isEmpty ? "" : text + "\n").utf8), to: historyPath)
    }

    /// 原子写：复用 S18 的发布器（临时文件 + 替换目标）；写入失败只告警，规格 S9 §9。
    private func writeAtomically(_ data: Data, to path: String) {
        let text = String(decoding: data, as: UTF8.self)
        do {
            try LocalFileSystem.writeAtomic(path: path, content: text)
        } catch {
            onWarning?("cron: 写入 \(path) 失败：\(error)")
        }
    }
}
