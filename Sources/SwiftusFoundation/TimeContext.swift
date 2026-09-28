import Foundation
import SwiftusCore

/// 时间锚点在 system prompt 里的名字（规格 S19 §3）。
public let kTimeContextName = "time"

/// 时间锚点在上下文之间的排序权重（靠前）。
public let kTimeContextOrder = -10

/// 一个瞬时时刻 + 它**自身时区**的展示信息。
///
/// 对应 Dart 的 `DateTime`（自带时区）：日期 / 星期 / 偏移都取自 `secondsFromGMT`
/// 对应的时区，而 `zoneName` 只是**显示名覆盖**——两者相互独立（S19 §3）。
public struct ZonedInstant: Sendable, Equatable {
    /// 瞬时时刻（绝对时间）。
    public let date: Date
    /// 展示用时区名；由调用方给定时覆盖，缺省用时区缩写。
    public let zoneName: String
    /// 该时刻的 UTC 偏移（秒）。
    public let secondsFromGMT: Int

    public init(date: Date, zoneName: String, secondsFromGMT: Int) {
        self.date = date
        self.zoneName = zoneName
        self.secondsFromGMT = secondsFromGMT
    }
}

/// 取「某个绝对时刻的带时区形态」的注入项。
public typealias ZonedInstantProvider = @Sendable (Date) -> ZonedInstant

extension ZonedInstant {
    /// 系统实现：本地时区（可覆盖显示名）。
    public static func system(zoneName: String? = nil) -> ZonedInstantProvider {
        { date in
            let zone = TimeZone.current
            let offset = zone.secondsFromGMT(for: date)
            let name = zoneName ?? zone.abbreviation(for: date) ?? zone.identifier
            return ZonedInstant(date: date, zoneName: name, secondsFromGMT: offset)
        }
    }
}

/// 把日粒度的当前日期注册为一份动态 prompt 上下文（规格 S19 §3）。
///
/// 每轮装配重新求值，因此跨天自动更新；**锚点只精确到日**（秒级变化会让可缓存的
/// system 前缀每轮失效）。
@ContextTreeActor
@discardableResult
public func provideTimePrompt(
    _ ctx: Context,
    prompt: SystemPrompt? = nil,
    zone: @escaping ZonedInstantProvider = ZonedInstant.system()
) throws -> Disposer {
    let target = try prompt ?? ctx.require(.systemPrompt)
    return try target.context(PromptContext(name: kTimeContextName, order: kTimeContextOrder) {
        renderAnchor(zone(Date()))
    })
}

/// 渲染日粒度锚点文本（规格 S19 §3）。
public func renderAnchor(_ instant: ZonedInstant) -> String {
    let zone = TimeZone(secondsFromGMT: instant.secondsFromGMT) ?? TimeZone(secondsFromGMT: 0)!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    calendar.locale = Locale(identifier: "en_US_POSIX")
    let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: instant.date)
    // Foundation 的 weekday 是 1=周日…7=周六（与 Dart 的 1=周一相反），
    // 故按 Foundation 的序号直接查表，避免差一位。
    let weekday = weekdayNames[(parts.weekday ?? 1) - 1]
    let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    return "[当前时间]\n\(date) 周\(weekday) · \(instant.zoneName) "
        + "(UTC\(formatClockOffset(secondsFromGMT: instant.secondsFromGMT)))"
}

/// 时区偏移格式化为 `±HH:MM`（如 `+08:00`、`-05:30`；规格 S19 §3）。
public func formatClockOffset(secondsFromGMT: Int) -> String {
    let sign = secondsFromGMT < 0 ? "-" : "+"
    let minutes = abs(secondsFromGMT) / 60
    return String(format: "%@%02d:%02d", sign, minutes / 60, minutes % 60)
}

/// 时区偏移格式化为 `±HH:MM`（时长形态，与 Dart 的 `Duration` 重载同款）。
public func formatClockOffset(_ offset: Duration) -> String {
    let seconds = Int(offset.components.seconds)
    let sign = offset < .zero || seconds < 0 ? "-" : "+"
    let minutes = abs(seconds) / 60
    return String(format: "%@%02d:%02d", sign, minutes / 60, minutes % 60)
}

/// 按 Foundation 的 weekday 序号（1=周日 … 7=周六）索引。
private let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]
