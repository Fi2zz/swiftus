import Foundation
import SwiftusCore

/// 四位年份可表示范围的下界 `0001-01-01T00:00:00.000Z`。
public let minFourDigitYearInstant = Date(timeIntervalSince1970: -62_135_596_800)

/// 四位年份可表示范围的上界 `9999-12-31T23:59:59.999Z`。
public let maxFourDigitYearInstant = Date(timeIntervalSince1970: 253_402_300_799.999)

/// 安全整数上界（2^53−1）；秒数参数按它校验，避免换算毫秒时溢出。
public let kMaxSafeInteger = 9_007_199_254_740_991

/// 范围下界的毫秒值（模块内共用）。
let minFourDigitYearMillis = minFourDigitYearInstant.utcMilliseconds

/// 范围上界的毫秒值（模块内共用）。
let maxFourDigitYearMillis = maxFourDigitYearInstant.utcMilliseconds

/// Date 的整数毫秒桥（规格 S8 §2：规范 UTC 串毫秒固定三位，换算必须无损）。
extension Date {
    /// 自 Unix 纪元的整数毫秒（四位年份范围内 Double 精确表达，rounded 仅修正浮点尾差）。
    public var utcMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    /// 自整数毫秒构造。
    public init(utcMilliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(utcMilliseconds) / 1000)
    }
}

/// 共享的 UTC 公历（函数内构造，规避 Calendar 非 Sendable 的静态共享）。
var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// 把时刻格式化为四位年份、毫秒固定三位的规范 UTC 串（规格 S8 §2.1）。
public func formatUtcInstant(_ value: Date) -> String {
    let components = utcCalendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .second, .nanosecond],
        from: value
    )
    let year = String(format: "%04d", components.year ?? 0)
    let millis = String(format: "%03d", nanosToMillis(components.nanosecond ?? 0))
    let month = padTwo(components.month ?? 0)
    let day = padTwo(components.day ?? 0)
    let hour = padTwo(components.hour ?? 0)
    let minute = padTwo(components.minute ?? 0)
    let second = padTwo(components.second ?? 0)
    return "\(year)-\(month)-\(day)T\(hour):\(minute):\(second).\(millis)Z"
}

/// 纳秒 → 毫秒：最近毫秒舍入（规格 S8 实现注记：Double 时钟有亚毫秒噪声，
/// Dart 的截断微秒与整毫秒输入上等价；四舍五入修正确保毫秒三位稳定）。
func nanosToMillis(_ nanosecond: Int) -> Int {
    Int((Double(nanosecond) / 1_000_000).rounded())
}

/// 判断串是否符合规范 UTC 形状（不校验历日是否真实存在）。
public func matchesUtcInstantShape(_ value: String) -> Bool {
    // REASON: Regex 非 Sendable，字面量不能放顶层静态；与 tryParseUtcInstant 内的模式保持逐字一致。
    let utcInstantPattern = /^(?!0000)(?<year>\d{4})-(?<month>0[1-9]|1[0-2])-(?<day>0[1-9]|[12]\d|3[01])T(?<hour>[01]\d|2[0-3]):(?<minute>[0-5]\d):(?<second>[0-5]\d)\.(?<millisecond>\d{3})Z$/
    return value.wholeMatch(of: utcInstantPattern) != nil
}

/// 解析一条规范 UTC 串；形状不符或不是真实历日时返回 nil（规格 S8 §2.1 往返比对）。
public func tryParseUtcInstant(_ value: String) -> Date? {
    // REASON: 同上，Regex 字面量函数内构造。
    let utcInstantPattern = /^(?!0000)(?<year>\d{4})-(?<month>0[1-9]|1[0-2])-(?<day>0[1-9]|[12]\d|3[01])T(?<hour>[01]\d|2[0-3]):(?<minute>[0-5]\d):(?<second>[0-5]\d)\.(?<millisecond>\d{3})Z$/
    guard let match = value.wholeMatch(of: utcInstantPattern) else { return nil }
    guard let parsed = try? calendarInstant(CalendarParts(
        year: Int(match.year) ?? 0,
        month: Int(match.month) ?? 0,
        day: Int(match.day) ?? 0,
        hour: Int(match.hour) ?? 0,
        minute: Int(match.minute) ?? 0,
        second: Int(match.second) ?? 0,
        millisecond: Int(match.millisecond) ?? 0
    )) else { return nil }
    return formatUtcInstant(parsed) == value ? parsed : nil
}

/// 一组精确的日历字段（规格 S8 §2.2）。
public struct CalendarParts: Sendable, Equatable {
    /// 四位年份。
    public let year: Int
    /// 月份（1—12）。
    public let month: Int
    /// 日（1—31）。
    public let day: Int
    /// 小时（0—23）。
    public let hour: Int
    /// 分钟（0—59）。
    public let minute: Int
    /// 秒（0—59）。
    public let second: Int
    /// 毫秒（0—999）。
    public let millisecond: Int

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, millisecond: Int = 0) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.millisecond = millisecond
    }
}

/// 用明确的日历字段构造 UTC 时刻；字段会被自动规范化时抛错（规格 S8 §2.2）。
public func calendarInstant(_ parts: CalendarParts) throws -> Date {
    guard parts.year != 0, parts.year <= 9999 else {
        throw ScheduleInputError(.invalidRule, "The at value must be a real ISO calendar date and time.")
    }
    guard parts.hour <= 23, parts.minute <= 59, parts.second <= 59 else {
        throw ScheduleInputError(.invalidRule, "The at value must be a real ISO calendar date and time.")
    }
    var fields = DateComponents()
    fields.year = parts.year
    fields.month = parts.month
    fields.day = parts.day
    fields.hour = parts.hour
    fields.minute = parts.minute
    fields.second = parts.second
    fields.nanosecond = parts.millisecond * 1_000_000
    let calendar = utcCalendar
    guard let value = calendar.date(from: fields), fieldsKept(value, parts, calendar: calendar) else {
        throw ScheduleInputError(.invalidRule, "The at value must be a real ISO calendar date and time.")
    }
    return value
}

/// 构造后逐字段比对：任一字段被自动规范化（如 month=13 进位）即视为非法历日。
private func fieldsKept(_ date: Date, _ parts: CalendarParts, calendar: Calendar) -> Bool {
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
    let dateKept = c.year == parts.year && c.month == parts.month && c.day == parts.day
    let timeKept = c.hour == parts.hour && c.minute == parts.minute && c.second == parts.second
    let millisKept = nanosToMillis(c.nanosecond ?? -1) == parts.millisecond
    return dateKept && timeKept && millisKept
}

/// 校验目标严格位于未来且落在四位年份范围内，返回目标本身（规格 S8 §2.3）。
/// 边界含等号：`target == now` 判为 not_future。
public func futureInstant(_ target: Date, _ now: Date) throws -> Date {
    guard target >= minFourDigitYearInstant, target <= maxFourDigitYearInstant else {
        throw ScheduleInputError(
            .timeOutOfRange,
            "The scheduled time must be representable as a four-digit-year RFC 3339 UTC instant."
        )
    }
    guard target > now else {
        throw ScheduleInputError(.notFuture, "The scheduled time must be strictly in the future.")
    }
    return target
}

/// 判断一个秒数是否为可用的正安全整数（规格 S8 §2.4）。
public func safePositiveSeconds(_ value: Int) -> Bool {
    value > 0 && value <= kMaxSafeInteger
}

/// 解码一个持久记录里的规范四位年份 RFC 3339 UTC 时刻（规格 S8 §5）。
public func decodeInstant(_ value: JSONValue?) throws -> Date {
    guard case let .string(text) = value, matchesUtcInstantShape(text) else {
        throw ScheduleLogError("scheduledAt must be a canonical four-digit-year RFC 3339 UTC instant")
    }
    guard let parsed = tryParseUtcInstant(text) else {
        throw ScheduleLogError("scheduledAt is not a real UTC calendar instant")
    }
    return parsed
}

private func padTwo(_ value: Int) -> String {
    String(format: "%02d", value)
}
