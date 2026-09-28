import Foundation
import SwiftusCore

/// S7 golden fixture 用例（spec/fixtures/s7/*.json，由 tool/export_fixtures 从 Dart 侧导出）。
struct CompactionFixture {
    /// 输入事件：type + 可选 data。
    struct EventInput {
        let type: String
        let data: JSONValue?
    }

    /// 一轮压缩的脚本：keepRecent + 汇总产出（summary）或抛错（throwsMessage）。
    struct Round {
        let keepRecent: Int
        let summary: Summary?
        let throwsMessage: String?
    }

    /// 汇总产出脚本。
    struct Summary {
        let text: String
        let provider: String?
        let model: String?
    }

    /// 期望：results / log 以 JSONValue 层比对（log 的 data.error 为 contains 子串语义）。
    struct Expect {
        let results: [JSONValue]
        let log: [JSONValue]
        let previousSeen: [String]
        let summaryOf: String?
        let invariantViolations: [String]
    }

    let name: String
    let sessionId: String
    let events: [EventInput]
    let rounds: [Round]
    let expect: Expect
}

/// fixture 装载（方案书 §3.2 fixtures 运行器的装载半）：#filePath 推导仓库根 →
/// spec/fixtures/s7/*.json（按文件名排序，输出确定）。驱动与比对为 S7 专属，见 S7FixtureTests。
enum CompactionFixtureLoader {
    /// 装载全部 S7 fixtures（按文件名排序）。
    static func loadAll() throws -> [CompactionFixture] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "spec/fixtures/s7", directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path())
            .filter { $0.hasSuffix(".json") }
            .sorted()
        return try names.map { try load(directory.appending(path: $0)) }
    }

    /// 测试发现期不能抛错；装载失败时返回空，由 `fixturesLoaded` 测试报告。
    static func loadAllOrEmpty() -> [CompactionFixture] {
        (try? loadAll()) ?? []
    }

    private static func load(_ url: URL) throws -> CompactionFixture {
        let root = try JSONValue.parse(Data(contentsOf: url)).objectValue ?? [:]
        return CompactionFixture(
            name: root["name"]?.stringValue ?? url.lastPathComponent,
            sessionId: root["sessionId"]?.stringValue ?? "s1",
            events: (root["events"]?.arrayValue ?? []).map(decodeEvent),
            rounds: (root["rounds"]?.arrayValue ?? []).compactMap(decodeRound),
            expect: decodeExpect(root["expect"] ?? .object([:]))
        )
    }

    private static func decodeEvent(_ value: JSONValue) -> CompactionFixture.EventInput {
        let object = value.objectValue ?? [:]
        return CompactionFixture.EventInput(type: object["type"]?.stringValue ?? "", data: object["data"])
    }

    private static func decodeRound(_ value: JSONValue) -> CompactionFixture.Round? {
        guard let object = value.objectValue, let keepRecent = object["keepRecent"]?.intValue else {
            return nil
        }
        return CompactionFixture.Round(
            keepRecent: keepRecent,
            summary: object["summary"].flatMap(decodeSummary),
            throwsMessage: object["throws"]?.stringValue
        )
    }

    private static func decodeSummary(_ value: JSONValue) -> CompactionFixture.Summary? {
        guard let object = value.objectValue, let text = object["text"]?.stringValue else {
            return nil
        }
        return CompactionFixture.Summary(
            text: text,
            provider: object["provider"]?.stringValue,
            model: object["model"]?.stringValue
        )
    }

    private static func decodeExpect(_ value: JSONValue) -> CompactionFixture.Expect {
        let object = value.objectValue ?? [:]
        return CompactionFixture.Expect(
            results: object["results"]?.arrayValue ?? [],
            log: object["log"]?.arrayValue ?? [],
            previousSeen: object["previousSeen"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            summaryOf: object["summaryOf"]?.stringValue,
            invariantViolations: object["invariantViolations"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }
}
