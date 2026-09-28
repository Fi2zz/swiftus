import Foundation
import SwiftusCore

/// S8 golden fixture 用例（spec/fixtures/s8/*.json，由 tool/export_fixtures 从 Dart 侧导出）。
struct ScheduleFixture {
    /// 用例名。
    let name: String
    /// 分派标识：parse-at / create-record / fold / every-occurrence / due-decision /
    /// framing / service-flow。
    let kind: String
    /// 顶层对象原文（now 等公共字段）。
    let raw: JSONValue
    /// 用例数组（各 kind 形状不同，由 runner 解码）。
    let cases: [JSONValue]
}

/// fixture 装载（与 SwiftusCompactionTests/FixtureLoader.swift 同源的「定位 + 读 JSON」半；
/// 驱动与比对为 S8 专属，见 S8FixtureRunner）。
enum ScheduleFixtureLoader {
    /// 装载全部 S8 fixtures（按文件名排序）。
    static func loadAll() throws -> [ScheduleFixture] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "spec/fixtures/s8", directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path())
            .filter { $0.hasSuffix(".json") }
            .sorted()
        return try names.map { try load(directory.appending(path: $0)) }
    }

    /// 测试发现期不能抛错；装载失败时返回空，由 `fixturesLoaded` 测试报告。
    static func loadAllOrEmpty() -> [ScheduleFixture] {
        (try? loadAll()) ?? []
    }

    private static func load(_ url: URL) throws -> ScheduleFixture {
        let root = try JSONValue.parse(Data(contentsOf: url)).objectValue ?? [:]
        return ScheduleFixture(
            name: root["name"]?.stringValue ?? url.lastPathComponent,
            kind: root["kind"]?.stringValue ?? "",
            raw: .object(root),
            cases: root["cases"]?.arrayValue ?? []
        )
    }
}
