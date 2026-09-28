import Foundation
import SwiftusCore

/// 一条已解码的持久变更（规格 S8 §5）。
public enum ScheduleChange: Sendable, Equatable {
    /// 创建一条提醒记录。
    case create(ScheduleRecord)
    /// 删除一条活动提醒。
    case delete(String)
    /// 把一条提醒写入派发历史；固定间隔记录额外携带决策时点（一次性必须为 nil）。
    case dispatch(id: String, acceptedAt: Date?)
}

/// 解码一条持久变更；任何形状或取值违规都抛 ScheduleLogError（规格 S8 §5）。
public func decodeScheduleChange(_ value: JSONValue?) throws -> ScheduleChange {
    guard case let .object(object) = value else {
        throw ScheduleLogError("schedule/change payload must be an object")
    }
    guard object["version"] == .int(Int64(kScheduleChangeVersion)) else {
        throw ScheduleLogError("schedule/change version must be 1")
    }
    return try decodeOperation(object)
}

private func decodeOperation(_ object: [String: JSONValue]) throws -> ScheduleChange {
    if case .string("create") = object["operation"] {
        return try decodeCreate(object)
    }
    if case .string("delete") = object["operation"] {
        return try decodeDelete(object)
    }
    if case .string("dispatch") = object["operation"] {
        return try decodeDispatch(object)
    }
    throw ScheduleLogError("schedule/change operation must be create, delete, or dispatch")
}

private func decodeCreate(_ object: [String: JSONValue]) throws -> ScheduleChange {
    try requireExactKeys(object, ["version", "operation", "schedule"],
                         "schedule create must contain exactly version, operation, and schedule")
    return .create(try decodeScheduleRecord(object["schedule"]))
}

private func decodeDelete(_ object: [String: JSONValue]) throws -> ScheduleChange {
    try requireExactKeys(object, ["version", "operation", "id"],
                         "schedule delete must contain exactly version, operation, and id")
    return .delete(try decodeScheduleId(object["id"]))
}

/// dispatch 解码：恰好 {version, operation, id} 或再带 acceptedAt（规格 S8 §5）。
private func decodeDispatch(_ object: [String: JSONValue]) throws -> ScheduleChange {
    if exactKeys(object, ["version", "operation", "id"]) {
        return .dispatch(id: try decodeScheduleId(object["id"]), acceptedAt: nil)
    }
    if exactKeys(object, ["version", "operation", "id", "acceptedAt"]) {
        return .dispatch(
            id: try decodeScheduleId(object["id"]),
            acceptedAt: try decodeInstantOrThrow(object["acceptedAt"])
        )
    }
    throw ScheduleLogError("schedule dispatch must contain id and optional acceptedAt only")
}

/// 解码一条持久记录；键集合必须与该种类完全一致（规格 S8 §5）。
public func decodeScheduleRecord(_ value: JSONValue?) throws -> ScheduleRecord {
    guard case let .object(object) = value else {
        throw ScheduleLogError("schedule record must be an object")
    }
    if case .string("after") = object["kind"] {
        return try decodeAfter(object)
    }
    if case .string("at") = object["kind"] {
        return try decodeAt(object)
    }
    if case .string("every") = object["kind"] {
        return try decodeEvery(object)
    }
    throw ScheduleLogError("v1 schedule kind must be \"after\", \"at\", or \"every\"")
}

/// 解码一个会话内标识：非空字符串且不带首尾空白。
public func decodeScheduleId(_ value: JSONValue?) throws -> String {
    guard case let .string(id) = value,
          !id.isEmpty,
          id == id.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw ScheduleLogError("schedule id must be a non-empty string without surrounding whitespace")
    }
    return id
}

private func decodeAfter(_ object: [String: JSONValue]) throws -> ScheduleRecord {
    try requireExactKeys(object, ["id", "kind", "prompt", "afterSeconds", "scheduledAt"],
                         "after schedule must contain exactly id, kind, prompt, afterSeconds, and scheduledAt")
    let prompt = try decodePrompt(object["prompt"], kind: "after")
    guard case let .int(afterSeconds) = object["afterSeconds"], safePositiveSeconds(Int(afterSeconds)) else {
        throw ScheduleLogError("afterSeconds must be a positive safe integer")
    }
    return ScheduleRecord(
        id: try decodeScheduleId(object["id"]),
        kind: .after,
        prompt: prompt,
        scheduledAt: try decodeInstant(object["scheduledAt"]),
        afterSeconds: Int(afterSeconds)
    )
}

private func decodeAt(_ object: [String: JSONValue]) throws -> ScheduleRecord {
    try requireExactKeys(object, ["id", "kind", "prompt", "scheduledAt"],
                         "at schedule must contain exactly id, kind, prompt, and scheduledAt")
    return ScheduleRecord(
        id: try decodeScheduleId(object["id"]),
        kind: .at,
        prompt: try decodePrompt(object["prompt"], kind: "at"),
        scheduledAt: try decodeInstant(object["scheduledAt"])
    )
}

private func decodeEvery(_ object: [String: JSONValue]) throws -> ScheduleRecord {
    try requireExactKeys(object, ["id", "kind", "prompt", "everySeconds", "scheduledAt"],
                         "every schedule must contain exactly id, kind, prompt, everySeconds, and scheduledAt")
    let prompt = try decodePrompt(object["prompt"], kind: "every")
    guard case let .int(everySeconds) = object["everySeconds"],
          everySeconds >= kMinEveryIntervalSeconds,
          everySeconds <= kMaxSafeInteger / 1000 else {
        throw ScheduleLogError("everySeconds must be a safe integer of at least \(kMinEveryIntervalSeconds)")
    }
    return ScheduleRecord(
        id: try decodeScheduleId(object["id"]),
        kind: .every,
        prompt: prompt,
        scheduledAt: try decodeInstant(object["scheduledAt"]),
        everySeconds: Int(everySeconds)
    )
}

private func decodePrompt(_ value: JSONValue?, kind: String) throws -> String {
    guard case let .string(prompt) = value,
          !prompt.isEmpty,
          prompt == prompt.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw ScheduleLogError("\(kind) prompt must be non-empty and already trimmed")
    }
    return prompt
}

/// acceptedAt 解码；消息键名与 scheduledAt 共用同一规范（规格 S8 §5 引 decodeInstant）。
private func decodeInstantOrThrow(_ value: JSONValue?) throws -> Date {
    try decodeInstant(value)
}

private func requireExactKeys(_ object: [String: JSONValue], _ expected: [String], _ message: String) throws {
    guard exactKeys(object, expected) else {
        throw ScheduleLogError(message)
    }
}

private func exactKeys(_ object: [String: JSONValue], _ expected: [String]) -> Bool {
    guard object.count == expected.count else { return false }
    return expected.allSatisfy { object.keys.contains($0) }
}

/// 把标识渲染成可读的诊断片段（JSON 引号形式，规格 S8 §5）。
public func quoteScheduleId(_ id: String) -> String {
    jsonStringLiteral(id)
}
