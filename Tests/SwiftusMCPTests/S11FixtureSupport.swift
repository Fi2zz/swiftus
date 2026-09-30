import Foundation
import SwiftusCore
import Testing

/// S11 fixture（{name, kind, cases}）。
///
/// 本域**无时间语义**（无墙钟、无时区），故 fixture 里没有 `localZone` / `now`
/// 字段，导出器也不钉 TZ（与 S9 不同，见 exporter README 的 S11 段）。
struct S11Fixture {
    let name: String
    let kind: String
    let cases: [JSONValue]
}

enum S11FixtureLoader {
    /// 全部 kind。
    static let kinds = [
        "mcp-config", "mcp-protocol", "mcp-sse", "mcp-content",
        "mcp-risk", "mcp-client", "mcp-registry",
    ]

    /// fixture 名（按 kind 过滤、排序）——参数化用例只拿名字，
    /// 免得 swift-testing 失败时把整份 fixture 打进输出。
    static func names(kind: String) -> [String] {
        load(kind: kind).map(\.name)
    }

    /// 按名字取一份 fixture。
    static func load(named name: String) -> S11Fixture? {
        kinds.flatMap { load(kind: $0) }.first { $0.name == name }
    }

    /// 按 kind 装载 fixture（spec/fixtures/s11）。
    ///
    /// 装载不到任何 fixture 时调用方必须显式失败：参数化用例拿到空集合会被静默
    /// 跳过，于是「零 fixture 全绿」看起来像通过（本项目已吃过两次，见 HANDOFF）。
    static func load(kind: String) -> [S11Fixture] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "spec/fixtures/s11", directoryHint: .isDirectory)
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
                return S11Fixture(
                    name: root["name"]?.stringValue ?? name,
                    kind: kind,
                    cases: root["cases"]?.arrayValue ?? []
                )
            }
    }
}

/// 断言计数：每个 fixture 至少要比对一次。
///
/// 参数化用例里「一条都没比」（用例没跑到、投影键全被裁掉、解析失败走了
/// `continue`）都会表现为全绿——vacuously passing 的 fixture 比没有 fixture 更危险，
/// 故每个运行器结尾都要断言计数非零。
final class McpAssertionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func hit() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// 只保留 fixture `expect` 里出现过的投影键（两端不必各自维护一份键清单）。
func mcpProjectKeys(_ full: [String: JSONValue], _ expect: JSONValue) -> [String: JSONValue] {
    guard case let .object(want) = expect else { return full }
    var out: [String: JSONValue] = [:]
    for key in want.keys.sorted() {
        out[key] = full[key] ?? .null
    }
    return out
}

/// 深度求首个差异（最多三条），避免整坨 JSON 的失败输出淹没有效信息。
func mcpExpectSame(
    _ actual: [String: JSONValue],
    _ expected: [String: JSONValue],
    _ label: String,
    counter: McpAssertionCounter? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    counter?.hit()
    guard actual != expected else { return }
    for (path, got, want) in mcpDifferences(actual: .object(actual), expected: .object(expected)) {
        Issue.record(
            "「\(label)」\(path) 不一致\n  实际：\(mcpBrief(got))\n  期望：\(mcpBrief(want))",
            sourceLocation: sourceLocation
        )
    }
}

/// 结构化值比对（内容 / 风险 / 注册表生命周期投影）。
func mcpExpectValue(
    _ actual: JSONValue,
    _ expected: JSONValue,
    _ label: String,
    counter: McpAssertionCounter? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    counter?.hit()
    guard actual != expected else { return }
    Issue.record(
        "「\(label)」不一致\n  实际：\(mcpBrief(actual))\n  期望：\(mcpBrief(expected))",
        sourceLocation: sourceLocation
    )
}

private func mcpDifferences(
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
        found += mcpDifferences(actual: got[key] ?? .null, expected: want[key] ?? .null, path: child, limit: limit)
    }
    return found
}

/// 失败输出用的短文本。
///
/// **顶层标量必须包一层再序列化**：`JSONSerialization` 不接受顶层标量，会抛
/// ObjC 异常直接终止进程（本项目踩过，见坑 #5）。包成单元素数组既绕开限制，
/// 又让标量与结构的输出形态一致。
private func mcpBrief(_ value: JSONValue) -> String {
    let wrapped = JSONValue.array([value])
    guard let data = try? wrapped.jsonData() else { return "?" }
    return String(decoding: data, as: UTF8.self)
}
