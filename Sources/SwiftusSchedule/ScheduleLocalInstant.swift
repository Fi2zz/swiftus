import Foundation

/// 采样偏移的毫秒位移：本地读数前后各两天（规格 S8 §3.4）。
private let samplingDeltas: [Int64] = [-172_800_000, -86_400_000, 0, 86_400_000, 172_800_000]

/// 把本地墙钟读数解析为瞬时：DST 重叠取较早，缺口拒绝（规格 S8 §3.4）。
///
/// 采样前后两天内的可用偏移量，逐个回投射校验字段确实还原，因此不依赖任何
/// 进程级时区设置。
public func resolveLocalInstant(_ parts: CalendarParts, zone: TimeZone) throws -> Date {
    let localMillis = try calendarInstant(parts).utcMilliseconds
    let offsets = Set(samplingDeltas.map { project(clampedToRange(localMillis + $0), zone: zone).offset })
    let outcome = collectCandidates(localMillis: localMillis, offsets: offsets, parts: parts, zone: zone)
    guard let earliest = outcome.candidates.min() else {
        if outcome.outOfRange {
            throw ScheduleInputError(
                .timeOutOfRange,
                "The scheduled time must be representable as a four-digit-year RFC 3339 UTC instant."
            )
        }
        throw ScheduleInputError(
            .invalidRule,
            "The local at time does not exist in the selected time zone."
        )
    }
    return Date(utcMilliseconds: earliest)
}

/// 收集候选瞬时：回投校验字段还原；越界标记但不入列。
private func collectCandidates(
    localMillis: Int64,
    offsets: Set<Int64>,
    parts: CalendarParts,
    zone: TimeZone
) -> (candidates: [Int64], outOfRange: Bool) {
    var candidates: [Int64] = []
    var outOfRange = false
    for offset in offsets {
        let candidate = localMillis - offset
        if candidate < minFourDigitYearMillis || candidate > maxFourDigitYearMillis {
            outOfRange = true
            continue
        }
        if project(candidate, zone: zone).parts == parts {
            candidates.append(candidate)
        }
    }
    return (candidates, outOfRange)
}

private func clampedToRange(_ millis: Int64) -> Int64 {
    if millis < minFourDigitYearMillis { return minFourDigitYearMillis }
    if millis > maxFourDigitYearMillis { return maxFourDigitYearMillis }
    return millis
}

/// 投影：瞬时 → 该时区的日历字段与偏移量（毫秒）。
private func project(_ millis: Int64, zone: TimeZone) -> (parts: CalendarParts, offset: Int64) {
    let date = Date(utcMilliseconds: millis)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let c = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .second, .nanosecond],
        from: date
    )
    let parts = CalendarParts(
        year: c.year ?? 0,
        month: c.month ?? 0,
        day: c.day ?? 0,
        hour: c.hour ?? 0,
        minute: c.minute ?? 0,
        second: c.second ?? 0,
        millisecond: nanosToMillis(c.nanosecond ?? 0)
    )
    return (parts, Int64(zone.secondsFromGMT(for: date) * 1000))
}
