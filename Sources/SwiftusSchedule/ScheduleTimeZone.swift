import Foundation
import SwiftusCore

// REASON: Regex 非 Sendable，字面量不能放顶层静态；各模式函数内构造（坑 #2 注记）。

/// 解析 `schedule_create` 的 `at` 选择器（规格 S8 §3）：显式偏移串或本地日历对象。
public func resolveAtTarget(_ value: JSONValue?) throws -> Date {
    if case let .string(text) = value {
        return try parseOffsetInstant(text)
    }
    if case let .object(object) = value {
        return try resolveLocalAt(object)
    }
    throw ScheduleInputError(
        .invalidRule,
        "at must be an explicit-offset string or local calendar object."
    )
}

/// 解析严格偏移形态：缺省 Z 或偏移会被拒绝；`-00:00` 非法（规格 S8 §3.1）。
public func parseOffsetInstant(_ value: String) throws -> Date {
    let offsetInstantPattern = /^(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})T(?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2})(?:\.(?<fraction>\d{1,3}))?(?<zone>Z|(?<sign>[+-])(?<offsetHour>\d{2}):(?<offsetMinute>\d{2}))$/
    guard let match = value.wholeMatch(of: offsetInstantPattern) else {
        throw ScheduleInputError(
            .invalidRule,
            "at must use YYYY-MM-DDTHH:mm:ss with optional 1-3 digit fractional seconds and an explicit Z or numeric offset."
        )
    }
    let localEpoch = try calendarInstant(CalendarParts(
        year: Int(match.year) ?? 0,
        month: Int(match.month) ?? 0,
        day: Int(match.day) ?? 0,
        hour: Int(match.hour) ?? 0,
        minute: Int(match.minute) ?? 0,
        second: Int(match.second) ?? 0,
        millisecond: fractionMilliseconds(match.fraction)
    ))
    if match.zone == "Z" {
        return localEpoch
    }
    let offsetHour = Int(match.offsetHour ?? "") ?? 0
    let offsetMinute = Int(match.offsetMinute ?? "") ?? 0
    let negativeZero = match.sign == "-" && offsetHour == 0 && offsetMinute == 0
    guard offsetHour <= 23, offsetMinute <= 59, !negativeZero else {
        throw ScheduleInputError(.invalidRule, "The at numeric offset is invalid.")
    }
    let seconds = (offsetHour * 60 + offsetMinute) * 60
    return match.sign == "+"
        ? localEpoch - TimeInterval(seconds)
        : localEpoch + TimeInterval(seconds)
}

/// 解析本地日历对象形态：`date` / `time` / `time_zone` 三键缺一不可（规格 S8 §3.2）。
public func resolveLocalAt(_ value: [String: JSONValue]) throws -> Date {
    guard exactKeys(value, ["date", "time", "time_zone"]) else {
        throw ScheduleInputError(
            .invalidRule,
            "Local at must contain exactly date, time, and time_zone."
        )
    }
    guard case let .string(date) = value["date"], case let .string(time) = value["time"] else {
        throw ScheduleInputError(.invalidRule, "Local at date and time must be strings.")
    }
    guard case let .string(zone) = value["time_zone"] else {
        throw ScheduleInputError(.invalidTimeZone, "time_zone must be a string.")
    }
    return try resolveLocalInstant(parseLocalParts(date, time), zone: canonicalTimeZone(zone))
}

/// 解析 `date` 与 `time` 字段；任一项非法即拒绝（规格 S8 §3.2）。
public func parseLocalParts(_ date: String, _ time: String) throws -> CalendarParts {
    let localDatePattern = /^(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})$/
    let localTimePattern = /^(?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2})(?:\.(?<fraction>\d{1,3}))?$/
    guard let dateMatch = date.wholeMatch(of: localDatePattern),
          let timeMatch = time.wholeMatch(of: localTimePattern) else {
        throw ScheduleInputError(
            .invalidRule,
            "Local at requires date YYYY-MM-DD and time HH:mm:ss with optional one-to-three digit milliseconds."
        )
    }
    let parts = CalendarParts(
        year: Int(dateMatch.year) ?? 0,
        month: Int(dateMatch.month) ?? 0,
        day: Int(dateMatch.day) ?? 0,
        hour: Int(timeMatch.hour) ?? 0,
        minute: Int(timeMatch.minute) ?? 0,
        second: Int(timeMatch.second) ?? 0,
        millisecond: fractionMilliseconds(timeMatch.fraction)
    )
    _ = try calendarInstant(parts)
    return parts
}

/// 校验并解析一个 `UTC` 或 IANA `Area/Location` 时区名（规格 S8 §3.3）。
/// Foundation 内建 IANA 数据库，不引第三方库（实现注记）。
public func canonicalTimeZone(_ value: String) throws -> TimeZone {
    let ianaZonePattern = /^[A-Za-z][A-Za-z0-9_+.-]*(?:\/[A-Za-z0-9_+.-]+)+$/
    let shaped = value == "UTC" || value.wholeMatch(of: ianaZonePattern) != nil
    guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines), shaped else {
        throw ScheduleInputError(.invalidTimeZone, "time_zone must be UTC or a valid IANA Area/Location name.")
    }
    guard let zone = TimeZone(identifier: value) else {
        throw ScheduleInputError(.invalidTimeZone, "time_zone must be UTC or a valid IANA Area/Location name.")
    }
    return zone
}

/// 小数秒（1—3 位）右补零到毫秒。
private func fractionMilliseconds(_ fraction: Substring?) -> Int {
    guard let fraction else { return 0 }
    var text = String(fraction)
    while text.count < 3 {
        text += "0"
    }
    return Int(text) ?? 0
}

/// 键集合精确判定。
private func exactKeys(_ value: [String: JSONValue], _ expected: [String]) -> Bool {
    guard value.count == expected.count else { return false }
    return expected.allSatisfy { value.keys.contains($0) }
}
