import Foundation
import SwiftusCore
import SwiftusFoundation
import Testing

/// S18 fixture 装载（{name, kind, cases}）。
struct S18Fixture {
    let name: String
    let kind: String
    let raw: JSONValue
    let cases: [JSONValue]
}

enum S18FixtureLoader {
    /// 按 kind 装载 fixture；`spec` 缺省 s18（S19 起各自指定目录）。
    ///
    /// **装载不到任何 fixture 时调用方必须显式失败**：参数化用例拿到空集合会被
    /// 静默跳过，于是「零 fixture 全绿」看起来像通过（本项目已吃过一次：S19 的运行器
    /// 误用 s18 装载器，全部用例空跑）。故每个测试另有一条 `fixtureInventory` 断言。
    static func load(kind: String, spec: String = "s18") -> [S18Fixture] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "spec/fixtures/\(spec)", directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path()) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .compactMap { name in
                guard let root = try? JSONValue.parse(Data(contentsOf: directory.appending(path: name))).objectValue,
                      root["kind"]?.stringValue == kind else {
                    return nil
                }
                return S18Fixture(
                    name: root["name"]?.stringValue ?? name,
                    kind: kind,
                    raw: .object(root),
                    cases: root["cases"]?.arrayValue ?? []
                )
            }
    }
}

// MARK: - 投影与临时根

/// 本轮 fixtures 的临时根（真实路径，供 realpath 形态的键对齐）。
let s18Root: URL = {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "swiftus-s18-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // 解析符号链接（macOS 临时目录是 /var → /private/var 的链接），与 targetKey 同形。
    return URL(fileURLWithPath: dir.path).resolvingSymlinksInPath()
}()

/// 路径投影：临时根替换为 `<root>`，分隔符统一为 `/`。
func s18Path(_ raw: String) -> String {
    raw.replacingOccurrences(of: s18Root.path, with: "<root>")
        .replacingOccurrences(of: "\\", with: "/")
}

/// 按 fixture 的 `input.files` 铺文件；`<binary>` 表示写非法 UTF-8 字节。
func s18Materialize(_ input: JSONValue) {
    for spec in input["files"]?.arrayValue ?? [] {
        guard let name = spec["name"]?.stringValue else { continue }
        let path = s18Root.appending(path: name)
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let content = spec["content"]?.stringValue ?? ""
        if content == "<binary>" {
            FileManager.default.createFile(atPath: path.path, contents: Data([0xff, 0xfe, 0x00]))
        } else {
            try? Data(content.utf8).write(to: path)
        }
    }
}

func s18FileContent(_ relative: String) -> String? {
    try? String(contentsOf: s18Root.appending(path: relative), encoding: .utf8)
}

/// FsError → 线上错误码；其他错误给出类型名（暴露「抛了非 FsError」）。
func s18ErrorCode(_ error: any Error) -> String {
    (error as? FsError)?.code.rawValue ?? String(describing: type(of: error))
}

/// 执行一步并把异常收敛成 `{error: 线上错误码}`（不抛到测试外）。
@ContextTreeActor
func s18Attempt(_ body: () async throws -> JSONValue) async -> JSONValue {
    do {
        return try await body()
    } catch {
        return .object(["error": .string(s18ErrorCode(error))])
    }
}

/// 深度求首个差异（最多三条），避免整坨 JSON 的失败输出淹没有效信息。
func s18ExpectSame(
    _ actual: [String: JSONValue],
    _ expected: [String: JSONValue],
    _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard actual != expected else { return }
    for (path, got, want) in s18Differences(actual: .object(actual), expected: .object(expected)) {
        Issue.record(
            "「\(label)」\(path) 不一致\n  实际：\(s18Brief(got))\n  期望：\(s18Brief(want))",
            sourceLocation: sourceLocation
        )
    }
}

private func s18Differences(
    actual: JSONValue,
    expected: JSONValue,
    path: String = "",
    limit: Int = 3
) -> [(String, JSONValue, JSONValue)] {
    if actual == expected { return [] }
    guard case let .object(got) = actual, case let .object(want) = expected else {
        return [(path.isEmpty ? "(root)" : path, actual, expected)]
    }
    var found: [(String, JSONValue, JSONValue)] = []
    for key in want.keys.sorted() {
        if found.count >= limit { return found }
        let child = path.isEmpty ? key : "\(path).\(key)"
        found += s18Differences(
            actual: got[key] ?? .null,
            expected: want[key] ?? .null,
            path: child,
            limit: limit - found.count
        )
    }
    for key in got.keys.sorted() where want[key] == nil {
        if found.count >= limit { return found }
        found.append((path.isEmpty ? key : "\(path).\(key)", got[key] ?? .null, .null))
    }
    return found.isEmpty ? [(path.isEmpty ? "(root)" : path, actual, expected)] : found
}

private func s18Brief(_ value: JSONValue, limit: Int = 200) -> String {
    guard case let .string(text) = value else { return String(describing: value) }
    return text.count > limit ? String(text.prefix(limit)) + "…" : text
}


/// 装载自检：每个 kind 必须恰好命中一个 fixture 文件、且用例非空。
@Suite("fixtures 装载自检")
struct FixtureInventoryTests {
    @Test("s18 各 kind 恰好一件且用例非空", arguments: [
        "fs-paths", "fs-ops", "shell-resolve", "shell-run", "shell-start",
    ])
    func s18Inventory(_ kind: String) {
        let fixtures = S18FixtureLoader.load(kind: kind, spec: "s18")
        #expect(fixtures.count == 1, "\(kind) 应恰好命中一个 fixture 文件")
        #expect(fixtures.first?.cases.isEmpty == false, "\(kind) 的用例不应为空")
    }

    @Test("s19 各 kind 恰好一件且用例非空", arguments: [
        "database-hub", "database-unit", "database-json",
        "timer", "time-context", "logger", "loader",
    ])
    func s19Inventory(_ kind: String) {
        let fixtures = S18FixtureLoader.load(kind: kind, spec: "s19")
        #expect(fixtures.count == 1, "\(kind) 应恰好命中一个 fixture 文件")
        #expect(fixtures.first?.cases.isEmpty == false, "\(kind) 的用例不应为空")
    }
}
