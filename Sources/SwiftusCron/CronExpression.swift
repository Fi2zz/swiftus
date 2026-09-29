import Foundation
import SwiftusCore

/// 5 段字段的取值范围：分、时、日、月、周（0 与 7 都表示周日）（规格 S9 §4）。
public let kCronFieldRanges: [(min: Int, max: Int)] = [
    (0, 59), (0, 23), (1, 31), (1, 12), (0, 7),
]

/// `nextCronSlot` 的搜索上限：4 个闰年的毫秒数。
public let kCronSearchLimitMs: Double = Double(4 * 366 * 24 * 60) * 60_000

/// 解析后的 cron 表达式：5 个允许值集合 + dom/dow 是否裸星。
public struct CronExpression: Sendable, Equatable {
    public let minute: Set<Int>
    public let hour: Set<Int>
    public let dom: Set<Int>
    public let month: Set<Int>
    /// 星期集合（0 表示周日）。
    public let dow: Set<Int>
    /// dom 字段是否为裸 `*`。
    public let domStar: Bool
    /// dow 字段是否为裸 `*`。
    public let dowStar: Bool
}

/// 单个字段片段展开后的上下界与步进。
private struct FieldSlice {
    let lo: Int
    let hi: Int
    let step: Int
}

/// 解析一个 cron 字段为允许值集合；任一片段非法返回 nil。
public func parseCronField(_ field: String, _ min: Int, _ max: Int) -> Set<Int>? {
    var values: Set<Int> = []
    for part in field.split(separator: ",", omittingEmptySubsequences: false) {
        guard let slice = parseFieldPart(String(part), min, max) else { return nil }
        var value = slice.lo
        while value <= slice.hi {
            values.insert(value)
            value += slice.step
        }
    }
    return values.isEmpty ? nil : values
}

private func parseFieldPart(_ part: String, _ min: Int, _ max: Int) -> FieldSlice? {
    // 形状：`(*|数字)(-(数字))?(/(数字))?`。手写切分而非正则：段内没有元字符歧义，
    // 且 `Int(_:)` 天然按 base-10 解析，不需要对齐 NSRegularExpression 的行为。
    var body = part
    var step = 1
    var hasStep = false
    if let slash = body.firstIndex(of: "/") {
        guard let value = Int(body[body.index(after: slash)...]), value >= 1 else { return nil }
        step = value
        hasStep = true
        body = String(body[..<slash])
    }
    let lo: Int
    var hi: Int
    if body == "*" {
        lo = min
        hi = max
    } else if let dash = body.firstIndex(of: "-") {
        guard let head = Int(body[..<dash]), let tail = Int(body[body.index(after: dash)...]) else {
            return nil
        }
        lo = head
        hi = tail
    } else {
        guard let value = Int(body) else { return nil }
        lo = value
        // `a/n` 按 Vixie cron 语义展开为 `a..max`。
        hi = hasStep ? max : value
    }
    // 越界（lo < min、hi > max、lo > hi）即非法。
    if lo < min || hi > max || lo > hi { return nil }
    return FieldSlice(lo: lo, hi: hi, step: step)
}

/// 解析标准 5 段表达式（分 时 日 月 周）；字段数不符或任一字段非法返回 nil。
public func parseCronExpression(_ expression: String) -> CronExpression? {
    let fields = expression.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    guard fields.count == 5 else { return nil }
    var parsed: [Set<Int>] = []
    for (index, field) in fields.enumerated() {
        guard let values = parseCronField(field, kCronFieldRanges[index].min, kCronFieldRanges[index].max) else {
            return nil
        }
        parsed.append(values)
    }
    // 周日 7 归一为 0。
    if parsed[4].contains(7) {
        parsed[4].remove(7)
        parsed[4].insert(0)
    }
    return CronExpression(
        minute: parsed[0],
        hour: parsed[1],
        dom: parsed[2],
        month: parsed[3],
        dow: parsed[4],
        domStar: fields[2] == "*",
        dowStar: fields[4] == "*"
    )
}

/// 表达式是否匹配某个时刻（**按 `zone` 的本地字段**判断；分钟级精度由调用方保证）。
public func cronMatches(_ cron: CronExpression, _ date: Date, zone: TimeZone) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    guard cron.minute.contains(calendar.component(.minute, from: date)),
          cron.hour.contains(calendar.component(.hour, from: date)),
          cron.month.contains(calendar.component(.month, from: date)) else {
        return false
    }
    let domMatch = cron.dom.contains(calendar.component(.day, from: date))
    // 日与周同时受限时「任一匹配」，否则两者都匹配（标准 cron 语义）。
    //
    // 星期换算：Foundation 的 `weekday` 是 1=周日…7=周六，cron 约定是 0=周日…6=周六，
    // 故是**减一**而不是来源里的 `% 7`（来源的 `DateTime.weekday` 是 1=周一…7=周日，
    // `% 7` 恰好等于这里的减一；照抄到 Foundation 编号上会把周日算成 1、周五算成 6）。
    let weekday = calendar.component(.weekday, from: date) - 1
    let dowMatch = cron.dow.contains(weekday)
    if cron.domStar || cron.dowStar { return domMatch && dowMatch }
    return domMatch || dowMatch
}

/// `after` 之后第一个匹配的本地分钟（严格大于）；4 年内无匹配返回 nil。
public func nextCronSlot(_ cron: CronExpression, after: Date, zone: TimeZone) -> Date? {
    // 锚点截断到整分钟后 +1 分钟。
    var candidate = floor(after.timeIntervalSince1970 / 60) * 60 + 60
    let limit = candidate + kCronSearchLimitMs
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    while candidate < limit {
        let instant = Date(timeIntervalSince1970: candidate)
        if cronMatches(cron, instant, zone: zone) { return instant }
        candidate += 60
    }
    return nil
}
