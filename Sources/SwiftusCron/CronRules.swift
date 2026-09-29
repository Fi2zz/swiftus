import Foundation
import SwiftusCore

/// 任务规则：输入校验、到期判定、下次触发时刻（规格 S9 §3 / §5）。
///
/// 全部是纯函数：`now` / `startedAt` / `firedAt` 一律由调用方传入，**不读墙钟**，
/// 时区由 `zone` 注入（生产用当前时区，fixtures 固定 UTC），保证可测与可回放。
/// 错误消息与来源保持一致（工具结果直接透出）。

/// 任务 id 形状：字母或数字开头，随后是字母、数字、`-`、`_`，最长 64 字符。
/// 正则按需构造（`Regex` 非 Sendable，不能做全局常量；见 HANDOFF）。
func cronTaskIdRegex() -> Regex<Substring> {
    /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/
}

/// daily 规则形状：本地 24 小时制的 `HH:MM`；第 1 组是时、第 2 组是分。
func cronDailyRegex() -> Regex<(Substring, Substring, Substring)> {
    /^([01]\d|2[0-3]):([0-5]\d)$/
}

/// 任务输入的原始形状（未经校验）。
public struct CronTaskInput: Sendable {
    public var id: JSONValue?
    public var prompt: JSONValue?
    public var at: JSONValue?
    public var every: JSONValue?
    public var daily: JSONValue?
    public var cron: JSONValue?

    public init(
        id: JSONValue? = nil,
        prompt: JSONValue? = nil,
        at: JSONValue? = nil,
        every: JSONValue? = nil,
        daily: JSONValue? = nil,
        cron: JSONValue? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.at = at
        self.every = every
        self.daily = daily
        self.cron = cron
    }

    /// 从动态 JSON 对象构造（工具入参形状）。
    public init(_ raw: [String: JSONValue]) {
        self.init(
            id: raw["id"],
            prompt: raw["prompt"],
            at: raw["at"],
            every: raw["every"],
            daily: raw["daily"],
            cron: raw["cron"]
        )
    }
}

/// 校验任务输入；返回错误消息或 nil（规格 S9 §3）。
public func validateCronTaskInput(_ input: CronTaskInput) -> String? {
    if let idError = validateCronId(input.id) { return idError }
    if let shapeError = validateCronShape(input) { return shapeError }
    let id = input.id?.stringValue ?? ""
    return validateCronAt(id, input.at)
        ?? validateCronEvery(id, input.every)
        ?? validateCronDaily(id, input.daily)
        ?? validateCronExpressionField(id, input.cron)
}

private func validateCronId(_ id: JSONValue?) -> String? {
    let ok: Bool
    switch id {
    case .some(.string(let text)): ok = text.wholeMatch(of: cronTaskIdRegex()) != nil
    default: ok = false
    }
    return ok ? nil : "invalid task id: \(describeCronValue(id))"
}

/// 值的描述：字符串按 JSON 转义给出，非字符串按字面量（与来源一致）。
private func describeCronValue(_ value: JSONValue?) -> String {
    switch value {
    case .some(.string(let text)):
        cronJsonStringLiteral(text)
    case .some(let other):
        String(describing: other)
    case nil:
        "null"
    }
}

/// JSON 字符串字面量（带引号）。
///
/// **不能用 `JSONSerialization`**：它不接受顶层标量（会抛
/// `NSInvalidArgumentException`，且抛的是 ObjC 异常——Swift 侧接不住，测试进程直接崩）。
/// 转义规则与 Dart `jsonEncode` 一致：`"` `\` 与控制字符转义，`\u2028` / `\u2029`
/// 也转义（JS 侧历史坑），其余字符按 UTF-8 原样输出。
func cronJsonStringLiteral(_ text: String) -> String {
    var out = "\""
    for character in text.unicodeScalars {
        switch character {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{2028}", "\u{2029}":
            out += "\\u" + String(character.value, radix: 16, uppercase: false)
        default:
            if character.value < 0x20 {
                let hex = String(character.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(character)
            }
        }
    }
    return out + "\""
}

private func validateCronShape(_ input: CronTaskInput) -> String? {
    let promptOk: Bool
    if case .some(.string(let text)) = input.prompt {
        promptOk = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    } else {
        promptOk = false
    }
    let id = input.id?.stringValue ?? ""
    if !promptOk { return "task \"\(id)\" needs a non-empty prompt" }
    // 规则计数：at/daily/cron 按真值，every 按非 nil（来源的 JS 真值语义）。
    let active = [
        cronTruthy(input.at),
        input.every != nil,
        cronTruthy(input.daily),
        cronTruthy(input.cron),
    ].filter { $0 }.count
    if active != 1 {
        return "task \"\(id)\" must set exactly one of at / every / daily / cron"
    }
    return nil
}

private func validateCronAt(_ id: String, _ at: JSONValue?) -> String? {
    guard cronTruthy(at) else { return nil }
    guard case .some(.string(let text)) = at, CronInstant.parse(text) != nil else {
        return "task \"\(id)\" has an unparseable at value"
    }
    return nil
}

private func validateCronEvery(_ id: String, _ every: JSONValue?) -> String? {
    guard let every else { return nil }
    // every 已过校验不会到这里，这里按 JSONValue 两种数字形态取 Double。
    let value = cronNumber(every)
    guard let value, value.isFinite, value >= kCronMinEverySeconds else {
        return "task \"\(id)\" every must be a number >= \(Int(kCronMinEverySeconds))"
    }
    return nil
}

private func validateCronDaily(_ id: String, _ daily: JSONValue?) -> String? {
    guard cronTruthy(daily) else { return nil }
    guard case .some(.string(let text)) = daily,
          text.wholeMatch(of: cronDailyRegex()) != nil else {
        return "task \"\(id)\" daily must be \"HH:MM\" (24h)"
    }
    return nil
}

private func validateCronExpressionField(_ id: String, _ cron: JSONValue?) -> String? {
    guard cronTruthy(cron) else { return nil }
    guard case .some(.string(let text)) = cron, parseCronExpression(text) != nil else {
        return "task \"\(id)\" has an invalid cron expression "
            + "(want 5 fields: minute hour day month weekday)"
    }
    return nil
}

/// 真值判定：空串、0、false 都算「没填」。
func cronTruthy(_ value: JSONValue?) -> Bool {
    switch value {
    case .none, .some(.null): return false
    case .some(.bool(let flag)): return flag
    case .some(.int(let raw)): return raw != 0
    case .some(.double(let raw)): return raw != 0 && !raw.isNaN
    case .some(.string(let text)): return !text.isEmpty
    case .some(.array), .some(.object): return true
    }
}

/// 任务当前生效的规则种类（校验保证恰好一个）。
public func cronRuleKind(of task: CronTask) -> CronRuleKind {
    if task.at != nil { return .at }
    if task.every != nil { return .every }
    if task.daily != nil { return .daily }
    return .cron
}

/// 今天本地时间 daily 规则对应的时刻（可早于 now）。
public func cronDailySlot(_ daily: String, now: Date, zone: TimeZone) -> Date? {
    guard let match = daily.wholeMatch(of: cronDailyRegex()),
          let hour = Int(match.1), let minute = Int(match.2) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    var components = calendar.dateComponents([.year, .month, .day], from: now)
    components.hour = hour
    components.minute = minute
    components.second = 0
    return calendar.date(from: components)
}

/// 缓存的下一个 cron 触发分钟；缓存 miss 时按锚点重算并写回。
public func cronNextSlot(of task: CronTask, startedAt: Date, zone: TimeZone) -> Date? {
    if let cached = task.cronNext { return cached }
    guard let parsed = task.cronParsed else { return nil }
    let anchor = task.lastRunAt ?? startedAt.addingTimeInterval(-60)
    let next = nextCronSlot(parsed, after: anchor, zone: zone)
    task.cronNext = next
    return next
}

/// 任务此刻到期的时段；未到期、已消费或停用时返回 nil（规格 S9 §5）。
public func cronDueSlot(of task: CronTask, now: Date, startedAt: Date, zone: TimeZone) -> Date? {
    guard task.isEnabled else { return nil }
    switch cronRuleKind(of: task) {
    case .at: return cronAtDueSlot(task, now)
    case .every: return cronEveryDueSlot(task, now, startedAt)
    case .daily: return cronDailyDueSlot(task, now, zone)
    case .cron: return cronCronDueSlot(task, now, startedAt, zone)
    }
}

private func cronAtDueSlot(_ task: CronTask, _ now: Date) -> Date? {
    guard task.firedAt == nil, let text = task.at, let instant = CronInstant.parse(text) else { return nil }
    return now < instant ? nil : instant
}

/// 固定间隔的秒数：毫秒四舍五入（与来源一致，避免小数间隔的浮点漂移）。
func cronEveryInterval(_ seconds: Double) -> TimeInterval {
    (seconds * 1000).rounded() / 1000
}

private func cronEveryDueSlot(_ task: CronTask, _ now: Date, _ startedAt: Date) -> Date? {
    guard let every = task.every else { return nil }
    let slot = (task.lastRunAt ?? startedAt).addingTimeInterval(cronEveryInterval(every))
    return now < slot ? nil : slot
}

private func cronDailyDueSlot(_ task: CronTask, _ now: Date, _ zone: TimeZone) -> Date? {
    guard let daily = task.daily, let slot = cronDailySlot(daily, now: now, zone: zone) else { return nil }
    if slot > now { return nil }
    // 已运行过且不早于该时段 → 今天这一格已消费。
    if let last = task.lastRunAt, last >= slot { return nil }
    return slot
}

private func cronCronDueSlot(_ task: CronTask, _ now: Date, _ startedAt: Date, _ zone: TimeZone) -> Date? {
    guard let slot = cronNextSlot(of: task, startedAt: startedAt, zone: zone) else { return nil }
    return now < slot ? nil : slot
}

/// 列表展示用的下一次触发时刻；停用或一次性已消费返回 nil（规格 S9 §5）。
public func cronNextRunAt(of task: CronTask, now: Date, startedAt: Date, zone: TimeZone) -> Date? {
    guard task.isEnabled else { return nil }
    switch cronRuleKind(of: task) {
    case .at:
        guard task.firedAt == nil, let text = task.at else { return nil }
        return CronInstant.parse(text)
    case .every:
        guard let every = task.every else { return nil }
        return (task.lastRunAt ?? startedAt).addingTimeInterval(cronEveryInterval(every))
    case .daily:
        return cronDailyNextRun(task, now, zone)
    case .cron:
        return cronNextSlot(of: task, startedAt: startedAt, zone: zone)
    }
}

private func cronDailyNextRun(_ task: CronTask, _ now: Date, _ zone: TimeZone) -> Date? {
    guard let daily = task.daily, let slot = cronDailySlot(daily, now: now, zone: zone) else { return nil }
    if slot > now { return slot }
    // 今天这格还没跑过（从未运行、或上次运行早于这一格）→ 就是这一格；否则顺延一天。
    guard let last = task.lastRunAt, last >= slot else { return slot }
    return slot.addingTimeInterval(24 * 60 * 60)
}

/// 生成一个任务 id：时间有序 base36 毫秒 + base36 随机后缀（4 位）（规格 S9 §1）。
public func generateCronTaskId(now: Date, randomSuffix: Int) -> String {
    let millis = Int(now.timeIntervalSince1970 * 1000)
    return "task-\(radix36(millis))-\(paddedRadix36(randomSuffix, width: 4))"
}

func radix36(_ value: Int) -> String {
    let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    var n = value
    var out = ""
    repeat {
        out = String(alphabet[n % 36]) + out
        n /= 36
    } while n > 0
    return out.isEmpty ? "0" : out
}

func paddedRadix36(_ value: Int, width: Int) -> String {
    let text = radix36(value)
    return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
}
