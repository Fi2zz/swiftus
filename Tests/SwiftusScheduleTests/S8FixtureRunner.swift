import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusSchedule
import Testing

/// 规格 S8 golden fixtures：按 kind 分派驱动 Swift 实现并比对 Dart 导出的期望。
/// 时间一律以规范 UTC 串往返；错误码比对 rawValue。
@ContextTreeActor
enum S8FixtureRunner {
    private static let runners: [String: (ScheduleFixture) async throws -> Void] = [
        "parse-at": runParseAt,
        "create-record": runCreateRecord,
        "fold": S8FixtureSessionRunner.runFold,
        "every-occurrence": S8FixtureSessionRunner.runEveryOccurrence,
        "due-decision": S8FixtureSessionRunner.runDueDecision,
        "framing": runFraming,
        "service-flow": S8FixtureSessionRunner.runServiceFlow,
    ]

    static func run(_ fixture: ScheduleFixture) async throws {
        guard let runner = runners[fixture.kind] else {
            Issue.record("未知 fixture kind：\(fixture.kind)")
            return
        }
        try await runner(fixture)
    }

    // ─── parse-at：resolveAtTarget 输入 → instant 或 errorCode ───

    private static func runParseAt(_ fixture: ScheduleFixture) throws {
        for caseItem in fixture.cases {
            try checkParseAtCase(caseItem)
        }
    }

    private static func checkParseAtCase(_ caseItem: JSONValue) throws {
        let expect = caseItem["expect"]?.objectValue ?? [:]
        if let instant = expect["instant"]?.stringValue {
            let parsed = try resolveAtTarget(caseItem["input"])
            #expect(formatUtcInstant(parsed) == instant)
            return
        }
        expectInputError(expect, in: caseItem) {
            _ = try resolveAtTarget(caseItem["input"])
        }
    }

    // ─── create-record：三选择器创建 → record 或 errorCode ───

    private static func runCreateRecord(_ fixture: ScheduleFixture) throws {
        let now = try requireInstant(fixture.raw["now"])
        for caseItem in fixture.cases {
            try checkCreateCase(caseItem, now: now)
        }
    }

    private static func checkCreateCase(_ caseItem: JSONValue, now: Date) throws {
        let selector = caseItem["selector"]?.objectValue ?? [:]
        let prompt = caseItem["prompt"]?.stringValue ?? ""
        let expect = caseItem["expect"]?.objectValue ?? [:]
        if let expectedRecord = expect["record"] {
            let record = try makeRecord(selector: selector, prompt: prompt, now: now)
            #expect(record.jsonValue == expectedRecord)
            return
        }
        expectInputError(expect, in: caseItem) {
            _ = try makeRecord(selector: selector, prompt: prompt, now: now)
        }
    }

    private static func makeRecord(selector: [String: JSONValue], prompt: String, now: Date) throws -> ScheduleRecord {
        if let at = selector["at"] {
            return try createAtRecord(id: "schedule-1", prompt: prompt, at: at, now: now)
        }
        if case let .int(afterSeconds) = selector["afterSeconds"] {
            return try createAfterRecord(id: "schedule-1", prompt: prompt, afterSeconds: Int(afterSeconds), now: now)
        }
        guard case let .int(everySeconds) = selector["everySeconds"] else {
            throw ScheduleInputError(.invalidRule, "fixture selector 缺失")
        }
        return try createEveryRecord(id: "schedule-1", prompt: prompt, everySeconds: Int(everySeconds), now: now)
    }

    // ─── framing：渲染快照逐字符比对 ───

    private static func runFraming(_ fixture: ScheduleFixture) throws {
        for caseItem in fixture.cases {
            try checkFramingCase(caseItem)
        }
    }

    private static func checkFramingCase(_ caseItem: JSONValue) throws {
        let expected = caseItem["expect"]?.objectValue?["text"]?.stringValue ?? ""
        if let record = caseItem["record"] {
            #expect(try renderReminderFraming(decodeScheduleRecord(record)) == expected)
            return
        }
        if let records = caseItem["records"]?.arrayValue {
            let dues = try zip(records, caseItem["occurrenceAts"]?.arrayValue ?? []).map { record, at in
                try ScheduleDue(
                    record: decodeScheduleRecord(record),
                    occurrenceAt: requireInstant(at)
                )
            }
            #expect(renderReminderBatchFraming(dues) == expected)
            return
        }
        #expect(renderDueFraming(.wait(nil)) == expected)
    }

    // ─── 共用辅助 ───

    /// 期望一次 ScheduleInputError 且错误码一致。
    static func expectInputError(
        _ expect: [String: JSONValue],
        in caseItem: JSONValue,
        _ body: () throws -> Void
    ) {
        let code = expect["errorCode"]?.stringValue ?? ""
        do {
            try body()
            Issue.record("期望抛出 errorCode \(code)，实际成功（\(caseItem)）")
        } catch let error as ScheduleInputError {
            #expect(error.code.rawValue == code)
        } catch {
            Issue.record("期望 ScheduleInputError(\(code))，实际 \(error)")
        }
    }

    /// 规范 UTC 串 → Date；fixture 数据必须合法。
    static func requireInstant(_ value: JSONValue?) throws -> Date {
        guard let text = value?.stringValue, let instant = tryParseUtcInstant(text) else {
            Issue.record("fixture 含非法时刻：\(value?.stringValue ?? "nil")")
            return Date(timeIntervalSince1970: 0)
        }
        return instant
    }
}
