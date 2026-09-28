import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusSchedule
import Testing

/// S8 fixtures 的会话侧运行器：fold / every-occurrence / due-decision / service-flow。
/// 挂载到 S8FixtureRunner 的分派表（本文件的函数被 S8FixtureRunner.runners 引用）。
@ContextTreeActor
enum S8FixtureSessionRunner {
    // ─── fold：schedule/change 事件流 → active / seenIds 或 corrupt 消息逐字比对 ───

    static func runFold(_ fixture: ScheduleFixture) throws {
        for caseItem in fixture.cases {
            try checkFoldCase(caseItem)
        }
    }

    private static func checkFoldCase(_ caseItem: JSONValue) throws {
        let session = try Session(id: "s1")
        for event in caseItem["events"]?.arrayValue ?? [] {
            try session.append(kScheduleChangeEvent, data: event)
        }
        let expect = caseItem["expect"]?.objectValue ?? [:]
        if let corrupt = expect["corrupt"]?.stringValue {
            expectCorrupt(corrupt) {
                _ = try foldScheduleEvents(session.ownEvents)
            }
            return
        }
        let folded = try foldScheduleEvents(session.ownEvents)
        #expect(folded.active.map(\.jsonValue) == (expect["active"]?.arrayValue ?? []))
        #expect(folded.seenIds == (expect["seenIds"]?.arrayValue?.compactMap(\.stringValue) ?? []))
    }

    // ─── every-occurrence：固定间隔算术 ───

    static func runEveryOccurrence(_ fixture: ScheduleFixture) throws {
        for caseItem in fixture.cases {
            try checkOccurrenceCase(caseItem)
        }
    }

    private static func checkOccurrenceCase(_ caseItem: JSONValue) throws {
        let input = caseItem["input"]?.objectValue ?? [:]
        let expect = caseItem["expect"]?.objectValue ?? [:]
        let record = ScheduleRecord(
            id: "schedule-1",
            kind: .every,
            prompt: "检查",
            scheduledAt: try S8FixtureRunner.requireInstant(input["scheduledAt"]),
            everySeconds: input["everySeconds"]?.intValue
        )
        let acceptedAt = try S8FixtureRunner.requireInstant(input["acceptedAt"])
        if let corrupt = expect["corrupt"]?.stringValue {
            expectCorrupt(corrupt) {
                _ = try resolveEveryOccurrence(record, acceptedAt: acceptedAt)
            }
            return
        }
        let occurrence = try resolveEveryOccurrence(record, acceptedAt: acceptedAt)
        #expect(formatUtcInstant(occurrence.occurrenceAt) == expect["occurrenceAt"]?.stringValue)
        #expect(occurrence.nextScheduledAt.map(formatUtcInstant) == expect["nextScheduledAt"]?.stringValue)
    }

    // ─── due-decision：到期决策 ───

    static func runDueDecision(_ fixture: ScheduleFixture) throws {
        for caseItem in fixture.cases {
            try checkDecisionCase(caseItem)
        }
    }

    private static func checkDecisionCase(_ caseItem: JSONValue) throws {
        let records = try (caseItem["active"]?.arrayValue ?? []).map { try decodeScheduleRecord($0) }
        let folded = ScheduleFold(active: records, seenIds: records.map(\.id))
        let now = try S8FixtureRunner.requireInstant(caseItem["now"])
        let decision = try dueDecision(folded, now)
        #expect(decisionJson(decision) == (caseItem["expect"] ?? .null))
    }

    private static func decisionJson(_ decision: DueDecision) -> JSONValue {
        if case let .oneShot(record) = decision {
            return .object(["type": .string("one-shot"), "id": .string(record.id)])
        }
        if case let .everyBatch(reminders, acceptedAt) = decision {
            return .object([
                "type": .string("every-batch"),
                "acceptedAt": .string(formatUtcInstant(acceptedAt)),
                "items": .array(reminders.map { due in
                    .object([
                        "id": .string(due.record.id),
                        "occurrenceAt": .string(formatUtcInstant(due.occurrenceAt)),
                    ])
                }),
            ])
        }
        guard case let .wait(target) = decision else { return .null }
        return .object([
            "type": .string("wait"),
            "target": target.map { .string(formatUtcInstant($0)) } ?? .null,
        ])
    }

    // ─── service-flow：固定时钟的服务端到端（create/list/delete/fork） ───

    static func runServiceFlow(_ fixture: ScheduleFixture) async throws {
        let now = try S8FixtureRunner.requireInstant(fixture.raw["now"])
        let expect = fixture.raw["expect"]?.objectValue ?? [:]
        let session = try Session(id: "s1")
        let schedule = SessionSchedule(session: session, clock: { now })
        let created = try await schedule.create(prompt: " 到点了 ", afterSeconds: 600)
        #expect(created.jsonValue == expect["created"])
        let listed = try await schedule.list()
        #expect(listed.map(\.jsonValue) == expect["listed"]?.arrayValue)
        let deleted = try await schedule.delete("schedule-1")
        #expect(deleted.jsonValue == expect["deleted"])
        let afterDelete = try await schedule.list()
        #expect(afterDelete.map(\.jsonValue) == (expect["afterDelete"]?.arrayValue ?? []))
        let forked = try session.fork(id: "s1-fork-1")
        let forkedActive = try foldScheduleEvents(forked.ownEvents).active
        #expect(forkedActive.isEmpty == (expect["forkedActiveEmpty"] == .bool(true)))
        let log = session.ownEvents.map { event in
            JSONValue.object([
                "seq": .int(Int64(event.seq)),
                "type": .string(event.type),
                "data": event.data ?? .null,
            ])
        }
        #expect(log == expect["log"]?.arrayValue)
    }

    // ─── 共用 ───

    /// 期望一次 ScheduleLogError 且不变式消息逐字一致（含引号片段）。
    private static func expectCorrupt(_ message: String, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("期望 corrupt：\(message)，实际成功")
        } catch let error as ScheduleLogError {
            #expect(error.message == message)
        } catch {
            Issue.record("期望 ScheduleLogError，实际 \(error)")
        }
    }
}
