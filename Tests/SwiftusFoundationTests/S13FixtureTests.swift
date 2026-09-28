import Foundation
import SwiftusCore
import SwiftusFoundation
import Testing

/// 规格 S13 golden fixtures：召回打分 / 遗忘与治理 / JSON 后端往返。
@Suite("S13 golden fixtures")
struct S13FixtureTests {
    private static let fixtures = S13FixtureLoader.loadAllOrEmpty()

    @Test("fixtures 已装载（spec/fixtures/s13/*.json）")
    func fixturesLoaded() {
        #expect(Self.fixtures.count >= 3)
    }

    @Test("recall-scoring", arguments: Self.fixtures.filter { $0.kind == "recall-scoring" })
    @ContextTreeActor
    func recallScoring(_ fixture: S13Fixture) async throws {
        let memory = try MemoryStore()
        try await memory.remember("用户喜欢京剧", tags: ["偏好"])
        try await memory.remember("用户喜欢喝咖啡", tags: ["偏好"])
        try await memory.remember("love coffee in the morning", tags: [])
        for caseItem in fixture.cases {
            let query = caseItem["query"]?.stringValue ?? ""
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let texts = memory.recall(query).map(\.text)
            #expect(texts == (expect["texts"]?.arrayValue?.compactMap(\.stringValue) ?? []), "\(caseItem["label"]?.stringValue ?? "")")
            if let limitOne = expect["limitOne"]?.arrayValue {
                // 与导出器一致：limit 截断用例的查询是「喜欢」。
                let limited = memory.recall("喜欢", limit: 1).map(\.text)
                #expect(limited == limitOne.compactMap(\.stringValue))
            }
        }
    }

    @Test("forget-and-govern", arguments: Self.fixtures.filter { $0.kind == "forget-and-govern" })
    @ContextTreeActor
    func forgetAndGovern(_ fixture: S13Fixture) async throws {
        let expect = fixture.raw["expect"]?.objectValue ?? [:]
        let memory = try MemoryStore(maxEntries: 2)
        let first = try await memory.remember("第一条")
        try await memory.remember("第二条")
        try await memory.remember("第三条")
        #expect(memory.allEntries.map(\.text) == (expect["afterGovern"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        let forgot = try await memory.forget(first.id)
        #expect(forgot == (expect["forgot"] == .bool(true)))
        try await memory.remember("第二条副本")
        let byText = try await memory.forgetByText("第二条副本")
        #expect(byText == expect["byText"]?.intValue)
        try await memory.remember("含关键字的条目")
        let matching = try await memory.forgetMatching("关键")
        #expect(matching == expect["matching"]?.intValue)
        try await memory.clear()
        #expect(memory.length == expect["lengthAfterClear"]?.intValue)
    }

    @Test("json-backend-roundtrip", arguments: Self.fixtures.filter { $0.kind == "json-backend-roundtrip" })
    @ContextTreeActor
    func jsonBackendRoundtrip(_ fixture: S13Fixture) async throws {
        let expect = fixture.raw["expect"]?.objectValue ?? [:]
        let dir = NSTemporaryDirectory() + "s13-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/memory.json"
        let memory = try MemoryStore(backend: JsonMemoryBackend(filePath: file))
        try await memory.remember("用户喜欢京剧", tags: ["偏好"])
        let reopened = try MemoryStore(backend: JsonMemoryBackend(filePath: file))
        try await reopened.load()
        #expect(reopened.allEntries.map(\.text) == (expect["reopenedTexts"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        #expect(reopened.allEntries.map { $0.tags.sorted() } == (expect["reopenedTags"]?.arrayValue?.map { $0.arrayValue?.compactMap(\.stringValue) ?? [] } ?? []))
    }
}

/// S13 fixture 装载。
struct S13Fixture {
    let name: String
    let kind: String
    let raw: JSONValue
    let cases: [JSONValue]
}

enum S13FixtureLoader {
    static func loadAllOrEmpty() -> [S13Fixture] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "spec/fixtures/s13", directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path()) else {
            return []
        }
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            guard let root = try? JSONValue.parse(Data(contentsOf: directory.appending(path: name))).objectValue else {
                return nil
            }
            return S13Fixture(
                name: root["name"]?.stringValue ?? name,
                kind: root["kind"]?.stringValue ?? "",
                raw: .object(root),
                cases: root["cases"]?.arrayValue ?? []
            )
        }
    }
}
