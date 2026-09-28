import Foundation
import os
import SwiftusCore
import SwiftusFoundation
import Testing

/// 规格 S4 golden fixtures：持久化端口 / SessionStore / SessionLog 双后端。
/// JSONL 行文本存在键序差异，一律按行解析为 JSONValue 后结构化比对。
@Suite("S4 golden fixtures")
struct S4FixtureTests {
    private static let fixtures = S4FixtureLoader.loadAllOrEmpty()

    @Test("fixtures 已装载（spec/fixtures/s4/*.json）")
    func fixturesLoaded() {
        #expect(!Self.fixtures.isEmpty)
    }

    @Test("jsonl-roundtrip", arguments: Self.fixtures.filter { $0.kind == "jsonl-roundtrip" })
    @ContextTreeActor
    func jsonlRoundtrip(_ fixture: S4Fixture) async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let persistence = try JsonlSessionPersistence(directory: dir)
        for eventValue in fixture.raw["events"]?.arrayValue ?? [] {
            try await persistence.append("s1", SessionEvent(jsonValue: eventValue))
        }
        let expect = fixture.raw["expect"]?.objectValue ?? [:]
        let lines = readLines("\(dir)/s1.jsonl")
        let expectedLines = expect["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(lines.count == expectedLines.count)
        for (actual, expected) in zip(lines, expectedLines) {
            #expect(try JSONValue.parse(Data(actual.utf8)) == JSONValue.parse(Data(expected.utf8)))
        }
        let loaded = try await persistence.load("s1")
        #expect(loaded.map(\.jsonValue) == expect["loaded"]?.arrayValue)
        #expect(try await persistence.list() == expect["list"]?.arrayValue?.compactMap(\.stringValue))
    }

    @Test("store-flow", arguments: Self.fixtures.filter { $0.kind == "store-flow" })
    @ContextTreeActor
    func storeFlow(_ fixture: S4Fixture) async throws {
        let expect = fixture.raw["expect"]?.objectValue ?? [:]
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let persistence = try JsonlSessionPersistence(directory: dir)
        let store = SessionStore(persistence: persistence)
        let session = try store.create(id: "s1")
        try session.append("user/message", data: .object(["text": .string("你好")]), time: fixedTime(0), id: "evt-a")
        try session.append("assistant/message", data: .object(["text": .string("在的")]), time: fixedTime(1), id: "evt-b")
        try await store.flush()
        #expect(readLines("\(dir)/s1.jsonl").count == expect["linesAfterFlush"]?.intValue)
        #expect(store.close("s1"))
        let reopened = try await store.open("s1")
        try reopened.append("user/message", data: .object(["text": .string("继续")]), time: fixedTime(2), id: "evt-c")
        try await store.flush()
        #expect(reopened.events.map(\.seq) == (expect["reopenedSeqs"]?.arrayValue?.compactMap(\.intValue) ?? []))
        #expect(reopened.events.map(\.type) == (expect["reopenedTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        let forked = try reopened.fork(id: "s1-fork-1")
        try store.adopt(forked)
        try await store.flush()
        #expect(readLines("\(dir)/s1-fork-1.jsonl").count == expect["forkLines"]?.intValue)
        #expect(forked.events.map(\.seq) == (expect["forkedSeqs"]?.arrayValue?.compactMap(\.intValue) ?? []))
        #expect(forked.events.map(\.id) == (expect["forkedIds"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        #expect(try await store.persistedIds() == expect["persistedIds"]?.arrayValue?.compactMap(\.stringValue))
        try await store.remove("s1")
        #expect(try await persistence.list() == expect["afterRemove"]?.arrayValue?.compactMap(\.stringValue))
    }

    @Test("log-flow", arguments: Self.fixtures.filter { $0.kind == "log-flow" })
    @ContextTreeActor
    func logFlow(_ fixture: S4Fixture) async throws {
        let expect = fixture.raw["expect"]?.objectValue ?? [:]
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = try makeLog(fixture.backend, dir: dir)
        var appendedSeqs: [Int] = []
        for index in 0..<3 {
            let event = SessionEvent(
                seq: 99,
                type: "e\(index)",
                time: fixedTime(index),
                id: "evt-\(index)",
                sessionId: "s1"
            )
            appendedSeqs.append(try await log.append(event).seq)
        }
        try await log.append(SessionEvent(seq: 0, type: "x", time: fixedTime(0), id: "evt-x", sessionId: "s2"))
        let forkedId = try await log.fork("s1", fromEventId: "evt-1")
        let forkedEvents = try await log.read(forkedId)
        let readWindow = try await log.read("s1", from: fixedTime(1), to: nil)
        let replayed = OSAllocatedUnfairLock<[String]>(initialState: [])
        try await log.replay("s1") { event in replayed.withLock { $0.append(event.type) } }
        let list = try await log.list()
        await log.close()
        #expect(appendedSeqs == (expect["appendedSeqs"]?.arrayValue?.compactMap(\.intValue) ?? []))
        #expect(forkedId == expect["forkedId"]?.stringValue)
        #expect(forkedEvents.map(\.jsonValue) == expect["forkedEvents"]?.arrayValue)
        #expect(readWindow.map(\.type) == (expect["readFromT1"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        #expect(replayed.withLock { $0 } == (expect["replayedTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        #expect(list == (expect["list"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        // persistence 后端：新实例 seq 从已落盘事件数续接
        if let continued = expect["continuedSeq"]?.intValue {
            let reopened = PersistenceSessionLog(try JsonlSessionPersistence(directory: dir))
            let event = SessionEvent(seq: 0, type: "e3", time: fixedTime(2), id: "evt-3", sessionId: "s1")
            #expect(try await reopened.append(event).seq == continued)
        }
    }

    /// 与导出器一致的时刻：2026-08-06T12:00:00Z（epoch 1786017600）起按分钟偏移。
    private func fixedTime(_ index: Int) -> Date {
        Date(timeIntervalSince1970: 1_786_017_600 + TimeInterval(index * 60))
    }

    @ContextTreeActor
    private func makeLog(_ backend: String, dir: String) throws -> any SessionLog {
        if backend == "memory" {
            return InMemorySessionLog()
        }
        return PersistenceSessionLog(try JsonlSessionPersistence(directory: dir))
    }

    private func makeTempDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "s4-\(UUID().uuidString)", directoryHint: .isDirectory)
            .path()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func readLines(_ path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// S4 fixture 装载（与既有 loader 同源的「定位 + 读 JSON」半）。
struct S4Fixture {
    let name: String
    let kind: String
    let backend: String
    let raw: JSONValue
}

enum S4FixtureLoader {
    static func loadAllOrEmpty() -> [S4Fixture] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "spec/fixtures/s4", directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path()) else {
            return []
        }
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            guard let root = try? JSONValue.parse(Data(contentsOf: directory.appending(path: name))).objectValue else {
                return nil
            }
            return S4Fixture(
                name: root["name"]?.stringValue ?? name,
                kind: root["kind"]?.stringValue ?? "",
                backend: root["backend"]?.stringValue ?? "",
                raw: .object(root)
            )
        }
    }
}
