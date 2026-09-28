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
    static func load(kind: String) -> [S18Fixture] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "spec/fixtures/s18", directoryHint: .isDirectory)
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
