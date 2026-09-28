import SwiftusCore
import SwiftusFoundation

/// 创建参数里允许出现的键（规格 S8 §11.2）。
public let kScheduleCreateKeys: Set<String> = ["prompt", "after_seconds", "at", "every_seconds"]

/// `schedule_create`：在当前会话里创建一条提醒。
///
/// 选择器三选一，形状类错误在读取或决策之前返回，通过后才进入持久化检查点。
@ContextTreeActor
public final class ScheduleCreateTool: Tool {
    private let schedule: SessionSchedule

    public init(schedule: SessionSchedule) {
        self.schedule = schedule
    }

    public let name = "schedule_create"

    public let description = "Create one reminder in the current session. Supply a non-empty prompt "
        + "and exactly one selector: a positive safe-integer after_seconds delay, "
        + "at as a strict offset date-time or local date/time object, or "
        + "safe-integer every_seconds of at least \(kMinEveryIntervalSeconds). "
        + "A relative delay is measured from creation time; resolve relative "
        + "dates against the current date given in the system prompt. When the "
        + "request is vague (such as \"later\" or \"in a while\"), do not invent a "
        + "delay: ask the user to pin down the timing first, or state the delay "
        + "you chose in the reply so it can be corrected. "
        + "Fixed-rate reminders stay creation-aligned, skip missed occurrences, and "
        + "batch one latest occurrence per overdue rule. Delivery is session-local: "
        + "the reminder runs on time only while this session is live and otherwise "
        + "becomes overdue until the session is resumed."

    public let riskLevel: ToolRisk = .medium

    public let group: String? = "schedule"

    public let params: [ParamSpec] = [
        .string("prompt", description: "Reminder content to present when the target becomes due.", required: true),
        .number("after_seconds", description: "Positive safe-integer delay in seconds, measured from creation time."),
        .number("every_seconds", description: "Fixed-rate safe-integer interval in seconds, at least \(kMinEveryIntervalSeconds)."),
    ]

    // REASON: `at` 是字符串或本地对象的二选一联合，ParamSpec 表达不了联合类型；
    // 这里按协议补齐 oneOf，参数模型本身保持单类型不变（规格 S8 §11.2）。
    public var schema: JSONValue {
        var parameters = parameterSchema(params).objectValue ?? [:]
        var properties = parameters["properties"]?.objectValue ?? [:]
        properties["at"] = atSchema
        parameters["properties"] = .object(properties)
        return .object([
            "name": .string(name),
            "description": .string(description),
            "parameters": .object(parameters),
        ])
    }

    public func call(_ context: ToolContext) async throws -> ToolResult {
        if let invalid = validateCreateArgs(context.arguments) {
            return scheduleErrorResult(invalid.code, invalid.message)
        }
        return await createResult(context.arguments)
    }

    private func createResult(_ args: [String: JSONValue]) async -> ToolResult {
        do {
            let view = try await schedule.create(
                prompt: args["prompt"]?.stringValue ?? "",
                afterSeconds: asSafeInteger(args["after_seconds"]),
                at: args["at"],
                everySeconds: asSafeInteger(args["every_seconds"])
            )
            return scheduleSuccessResult(view.jsonValue)
        } catch {
            return scheduleFailureResult(error)
        }
    }

    private var atSchema: JSONValue {
        .object([
            "description": .string("Absolute target as strict offset RFC 3339 or local date/time with an explicit IANA zone."),
            "oneOf": .array([
                .object(["type": .string("string")]),
                .object([
                    "type": .string("object"),
                    "properties": .object([
                        "date": .object(["type": .string("string")]),
                        "time": .object(["type": .string("string")]),
                        "time_zone": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("date"), .string("time"), .string("time_zone")]),
                ]),
            ]),
        ])
    }
}

/// 校验创建参数；返回 nil 表示可以进入服务层（规格 S8 §11.2：先选择器后规则）。
public func validateCreateArgs(_ args: [String: JSONValue]) -> (code: ScheduleErrorCode, message: String)? {
    if let selector = validateSelector(args) {
        return selector
    }
    return validateRule(args)
}

/// 选择器校验：未知键或选择器数 ≠ 1 → invalid_selector；prompt 空 → invalid_prompt。
private func validateSelector(_ args: [String: JSONValue]) -> (code: ScheduleErrorCode, message: String)? {
    let unknown = args.keys.contains { !kScheduleCreateKeys.contains($0) }
    let selectors = ["after_seconds", "at", "every_seconds"].filter { present(args, $0) }.count
    guard !unknown, selectors == 1 else {
        return (
            ScheduleErrorCode.invalidSelector,
            "schedule_create accepts exactly one of after_seconds, at, or every_seconds."
        )
    }
    guard case let .string(prompt) = args["prompt"],
          !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return (ScheduleErrorCode.invalidPrompt, "prompt must be non-empty after trimming.")
    }
    return nil
}

/// 规则校验：after_seconds 正安全整数；every_seconds 安全整数且 ≥ 300。
private func validateRule(_ args: [String: JSONValue]) -> (code: ScheduleErrorCode, message: String)? {
    if let raw = args["after_seconds"], raw != .null {
        guard let seconds = asSafeInteger(raw), seconds > 0 else {
            return (ScheduleErrorCode.invalidRule, "after_seconds must be a positive safe integer.")
        }
    }
    if let raw = args["every_seconds"], raw != .null {
        return validateEvery(raw)
    }
    return nil
}

private func validateEvery(_ raw: JSONValue) -> (code: ScheduleErrorCode, message: String)? {
    guard let seconds = asSafeInteger(raw) else {
        return (ScheduleErrorCode.invalidRule, "every_seconds must be a safe integer.")
    }
    guard seconds >= kMinEveryIntervalSeconds else {
        return (
            ScheduleErrorCode.frequencyTooHigh,
            "every_seconds must be at least \(kMinEveryIntervalSeconds)."
        )
    }
    return nil
}

/// 参数存在且非 null。
private func present(_ args: [String: JSONValue], _ key: String) -> Bool {
    guard let value = args[key], value != .null else { return false }
    return true
}

/// 把 JSON 数值收窄为安全整数；不是整数值或超出安全范围时返回 nil（规格 S8 §2.4）。
public func asSafeInteger(_ value: JSONValue?) -> Int? {
    if case let .int(number) = value {
        return number >= -maxSafeInt64 && number <= maxSafeInt64 ? Int(number) : nil
    }
    if case let .double(number) = value, number.isFinite, number == number.rounded() {
        return abs(number) <= Double(kMaxSafeInteger) ? Int(number) : nil
    }
    return nil
}

private let maxSafeInt64 = Int64(kMaxSafeInteger)
