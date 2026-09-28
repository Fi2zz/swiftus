import Foundation
import SwiftusCompaction
import SwiftusCore
import SwiftusFoundation
import Testing

/// fixture 汇总器抛错：description 即消息本身（与导出器剥前缀后的 error 子串对齐）。
private struct FixtureSummaryError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) {
        description = message
    }
}

/// 汇总器见到的 previous 记录盒（actor 域内共享）。
@ContextTreeActor
private final class PreviousLog {
    var seen: [String] = []
}

/// 规格 S7 golden fixtures：读 JSON → 驱动 Swift Compactor → 比对输出（方案书 §3.2）。
/// 用例由 tool/export_fixtures 从 Dart 侧行为导出；compactionId 归一化（<cmp-N>）后比对，
/// log 的 data.error 按 contains 子串比对（错误展示串的语言相关部分不是规格）。
@Suite("S7 golden fixtures")
struct S7FixtureTests {
    private static let fixtures = CompactionFixtureLoader.loadAllOrEmpty()

    @Test("fixtures 已装载（spec/fixtures/s7/*.json）")
    func fixturesLoaded() {
        #expect(!Self.fixtures.isEmpty)
    }

    @Test("golden fixture", arguments: Self.fixtures)
    @ContextTreeActor
    func goldenFixture(_ fixture: CompactionFixture) async throws {
        let session = try Session(id: fixture.sessionId)
        for event in fixture.events {
            try session.append(event.type, data: event.data)
        }
        let compactor = try Compactor(keepRecent: 20)
        let previousLog = PreviousLog()
        var results: [JSONValue] = []
        for round in fixture.rounds {
            results.append(await runRound(round, compactor: compactor, session: session, previousLog: previousLog))
        }
        #expect(results == fixture.expect.results)
        #expect(previousLog.seen == fixture.expect.previousSeen)
        #expect(compactor.summaryOf(session.id) == fixture.expect.summaryOf)
        let actualLog = normalizedLog(of: session)
        #expect(actualLog.count == fixture.expect.log.count)
        for (expected, actual) in zip(fixture.expect.log, actualLog) {
            #expect(jsonMatches(expected: expected, actual: actual))
        }
        #expect(checkCompactionInvariant(session.events) == fixture.expect.invariantViolations)
    }

    @ContextTreeActor
    private func runRound(
        _ round: CompactionFixture.Round,
        compactor: Compactor,
        session: Session,
        previousLog: PreviousLog
    ) async -> JSONValue {
        let summarizer: Summarizer = { _, previous in
            previousLog.seen.append(previous)
            if let message = round.throwsMessage {
                throw FixtureSummaryError(message)
            }
            guard let summary = round.summary else {
                throw FixtureSummaryError("fixture round 缺 summary")
            }
            return CompactionSummary(summary.text, provider: summary.provider, model: summary.model)
        }
        do {
            let result = try await compactor.compactIfNeeded(
                session,
                summarize: summarizer,
                keepRecent: round.keepRecent
            )
            return result.map(resultJson) ?? .null
        } catch {
            return .object(["threw": .bool(true)])
        }
    }

    private func resultJson(_ result: CompactionResult) -> JSONValue {
        .object([
            "compacted": .int(Int64(result.compacted)),
            "kept": .int(Int64(result.kept)),
            "shadowedSeqs": .array(result.shadowedSeqs.map { .int(Int64($0)) }),
            "startSeq": .int(Int64(result.startSeq)),
            "summarySeq": .int(Int64(result.summarySeq)),
            "endSeq": .int(Int64(result.endSeq)),
            "summary": .string(result.summary),
        ])
    }

    /// 实际日志的归一化投影（seq / type / data；compactionId 按首次出现顺序替换为 <cmp-N>）。
    @ContextTreeActor
    private func normalizedLog(of session: Session) -> [JSONValue] {
        var aliases: [String: String] = [:]
        return session.events.map { event in
            var entry: [String: JSONValue] = [
                "seq": .int(Int64(event.seq)),
                "type": .string(event.type),
            ]
            if let data = event.data {
                entry["data"] = normalizeData(data, aliases: &aliases)
            }
            return .object(entry)
        }
    }
}

/// log 比对：结构全等，唯独 error 键按 contains 子串比对。
private func jsonMatches(expected: JSONValue, actual: JSONValue, atErrorKey: Bool = false) -> Bool {
    if atErrorKey {
        return errorMatches(expected: expected, actual: actual)
    }
    if case let .object(want) = expected, case let .object(got) = actual {
        return objectMatches(expected: want, actual: got)
    }
    if case let .array(want) = expected, case let .array(got) = actual {
        return want.count == got.count && zip(want, got).allSatisfy { jsonMatches(expected: $0, actual: $1) }
    }
    return expected == actual
}

private func errorMatches(expected: JSONValue, actual: JSONValue) -> Bool {
    guard case let .string(want) = expected, case let .string(got) = actual else { return false }
    return got.contains(want)
}

private func objectMatches(expected: [String: JSONValue], actual: [String: JSONValue]) -> Bool {
    guard expected.count == actual.count else { return false }
    return expected.allSatisfy { key, want in
        actual[key].map { jsonMatches(expected: want, actual: $0, atErrorKey: key == "error") } ?? false
    }
}

private func normalizeData(_ value: JSONValue, aliases: inout [String: String]) -> JSONValue {
    if case let .object(object) = value {
        return normalizeObject(object, aliases: &aliases)
    }
    if case let .array(items) = value {
        return .array(items.map { normalizeData($0, aliases: &aliases) })
    }
    return value
}

private func normalizeObject(_ object: [String: JSONValue], aliases: inout [String: String]) -> JSONValue {
    var normalized: [String: JSONValue] = [:]
    for (key, child) in object {
        if key == "compactionId", case let .string(id) = child {
            normalized[key] = .string(alias(for: id, aliases: &aliases))
        } else {
            normalized[key] = normalizeData(child, aliases: &aliases)
        }
    }
    return .object(normalized)
}

private func alias(for id: String, aliases: inout [String: String]) -> String {
    if let existing = aliases[id] {
        return existing
    }
    let minted = "<cmp-\(aliases.count + 1)>"
    aliases[id] = minted
    return minted
}
