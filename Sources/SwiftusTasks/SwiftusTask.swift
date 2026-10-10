import Foundation
import SwiftusCore
import SwiftusFoundation

/// 任务变更事件类型（规格 S17 §1）。
public let kTaskEvent = "task/changed"

/// 恢复时未完成任务的统一失败原因（规格 S17 §1）。
public let kTaskStaleReason = "进程重启，执行环境已丢失"

/// 任务状态（规格 S17 §1）。
public enum TaskStatus: String, Sendable, CaseIterable {
    /// 已创建，等待执行。
    case pending
    /// 执行中。
    case running
    /// 暂停。
    case paused
    /// 完成（终态）。
    case completed
    /// 失败（终态）。
    case failed
    /// 取消（终态）。
    case cancelled

    /// 是否终态。
    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }

    /// 是否活跃（可被取消）；与终态互为补集。
    public var isActive: Bool {
        !isTerminal
    }

    /// 播报文案（规格 S17 §4）。
    public var spokenText: String {
        switch self {
        case .pending: return "等待中"
        case .running: return "进行中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "已失败"
        case .cancelled: return "已取消"
        }
    }
}

/// 任务类型（规格 S17 §1）。
public enum TaskKind: String, Sendable, CaseIterable {
    /// Agent Loop 的一轮。
    case agentTurn
    /// 子 Agent 委托。
    case subAgent
    /// 后台 shell 进程。
    case shell
    /// 定时提醒交付。
    case schedule
    /// 自定义。
    case custom
}

/// 任务相关错误（规格 S17 §1）。
///
/// 机器码全集：`not-found` / `already-terminal` / `cancelled` / `disposed`；
/// `invalid-created-at` 是 Swift 侧解码 `createdAt` 失败时的唯一新增码
/// （Dart 侧由 `DateTime.parse` 抛 FormatException，见规格 S17 §7）。
public enum TaskError: Error, Equatable {
    /// 任务不存在。
    case notFound(id: String)
    /// 任务已终态，不可再变更。
    case alreadyTerminal(id: String)
    /// 审批拒绝取消。
    case cancelled
    /// 任务中心已释放。
    case disposed
    /// 反序列化时 createdAt 缺失或非法。
    case invalidCreatedAt

    /// 稳定的机器可读错误码。
    public var code: String {
        switch self {
        case .notFound: return "not-found"
        case .alreadyTerminal: return "already-terminal"
        case .cancelled: return "cancelled"
        case .disposed: return "disposed"
        case .invalidCreatedAt: return "invalid-created-at"
        }
    }

    /// 面向用户 / 模型的可读消息。
    public var message: String {
        switch self {
        case let .notFound(id): return "任务 \(id) 不存在"
        case let .alreadyTerminal(id): return "任务 \(id) 已结束"
        case .cancelled: return "用户取消"
        case .disposed: return "任务中心已释放"
        case .invalidCreatedAt: return "任务 createdAt 缺失或非法"
        }
    }
}

extension TaskError: CustomStringConvertible {
    public var description: String {
        "TaskError(\(code)): \(message)"
    }
}

/// 一个任务（规格 S17 §1）：整值替换更新，每次状态变更写一条 `task/changed`。
public struct SwiftusTask: Sendable, Equatable {
    /// 任务唯一 ID。
    public let id: String
    /// 任务类型。
    public let kind: TaskKind
    /// 当前状态。
    public let status: TaskStatus
    /// 人类可读的描述。
    public let description: String
    /// 创建时间。
    public let createdAt: Date
    /// 开始时间（状态进入 running 时设置）。
    public let startedAt: Date?
    /// 结束时间（状态进入终态时设置）。
    public let finishedAt: Date?
    /// 父任务 ID；用于表达任务树（Goal → Agent Turn → Sub-Agent → Shell）。
    public let parentTaskId: String?
    /// 元数据；可放 goalId、maxRounds、command 等。
    public let metadata: [String: JSONValue]
    /// 结果（completed 时可选）。
    public let result: JSONValue?
    /// 错误（failed 时可选）。
    public let error: JSONValue?

    public init(
        id: String,
        kind: TaskKind,
        status: TaskStatus,
        description: String,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        parentTaskId: String? = nil,
        metadata: [String: JSONValue] = [:],
        result: JSONValue? = nil,
        error: JSONValue? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.description = description
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.parentTaskId = parentTaskId
        self.metadata = metadata
        self.result = result
        self.error = error
    }

    /// 是否终态。
    public var isTerminal: Bool {
        status.isTerminal
    }

    /// 是否活跃（可被取消）。
    public var isActive: Bool {
        status.isActive
    }

    /// 运行时长（未开始为 nil；未结束按 `now` 计）。
    public func duration(now: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    /// 返回更新后的副本；传空表示保持原值（清除可空字段请显式传 JSON null）。
    public func copyWith(
        status: TaskStatus? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        result: JSONValue? = nil,
        error: JSONValue? = nil
    ) -> SwiftusTask {
        SwiftusTask(
            id: id,
            kind: kind,
            status: status ?? self.status,
            description: description,
            createdAt: createdAt,
            startedAt: startedAt ?? self.startedAt,
            finishedAt: finishedAt ?? self.finishedAt,
            parentTaskId: parentTaskId,
            metadata: metadata,
            result: result ?? self.result,
            error: error ?? self.error
        )
    }

    /// 从 JSON 反序列化（恢复时 result / error 为 JSON 形态）。
    ///
    /// 宽容项：未知 kind → custom、未知 status → pending、startedAt / finishedAt
    /// 解析失败 → nil、metadata 非对象 → 空表。唯一不宽容项是 createdAt
    /// （缺失或非法抛 `TaskError.invalidCreatedAt`）。
    public init(jsonValue: JSONValue) throws {
        let object = jsonValue.objectValue ?? [:]
        id = object["id"]?.stringValue ?? ""
        kind = TaskKind(rawValue: object["kind"]?.stringValue ?? "") ?? .custom
        status = TaskStatus(rawValue: object["status"]?.stringValue ?? "") ?? .pending
        description = object["description"]?.stringValue ?? ""
        guard let createdRaw = object["createdAt"]?.stringValue,
              let created = parseTaskInstant(.string(createdRaw)) else {
            throw TaskError.invalidCreatedAt
        }
        createdAt = created
        startedAt = parseTaskInstant(object["startedAt"])
        finishedAt = parseTaskInstant(object["finishedAt"])
        parentTaskId = object["parentTaskId"]?.stringValue
        metadata = object["metadata"]?.objectValue ?? [:]
        result = object["result"].flatMap { $0 == .null ? nil : $0 }
        error = object["error"].flatMap { $0 == .null ? nil : $0 }
    }

    /// 序列化为 JSONValue：可空字段保留 null 键。
    public var jsonValue: JSONValue {
        .object([
            "id": .string(id),
            "kind": .string(kind.rawValue),
            "status": .string(status.rawValue),
            "description": .string(description),
            "createdAt": .string(taskInstantString(createdAt)),
            "startedAt": startedAt.map { .string(taskInstantString($0)) } ?? .null,
            "finishedAt": finishedAt.map { .string(taskInstantString($0)) } ?? .null,
            "parentTaskId": parentTaskId.map { .string($0) } ?? .null,
            "metadata": .object(metadata),
            "result": result ?? .null,
            "error": error ?? .null,
        ])
    }
}

/// 任务时刻宽容解析：先试带小数秒形态，再退回基本形态，失败按 nil。
func parseTaskInstant(_ value: JSONValue?) -> Date? {
    guard let text = value?.stringValue else { return nil }
    if let parsed = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
        return parsed
    }
    return try? Date(text, strategy: .iso8601)
}

/// 任务时刻序列化（ISO8601 带小数秒）。
func taskInstantString(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

/// 把任意错误归一为可编码的 JSON：非 JSON 值退化为字符串（规格 S17 §1）。
public func taskErrorValue(_ error: (any Error)?) -> JSONValue? {
    guard let error else { return nil }
    return .string(String(describing: error))
}

/// 折叠会话自身后缀里的 `task/changed` 事件，按任务 id 还原任务列表
///（每个 id 只保留最后一个事件，整值替换），顺序为 id 首次出现序
///（对齐 Dart LinkedHashMap 的插入序，规格 S17 §1）。
@ContextTreeActor
public func restoreTaskState(_ session: Session) throws -> [SwiftusTask] {
    var order: [String] = []
    var latest: [String: SwiftusTask] = [:]
    for event in session.ownEvents where event.type == kTaskEvent {
        guard let data = event.data, case .object = data else { continue }
        let task = try SwiftusTask(jsonValue: data)
        if latest[task.id] == nil {
            order.append(task.id)
        }
        latest[task.id] = task
    }
    return order.compactMap { latest[$0] }
}
