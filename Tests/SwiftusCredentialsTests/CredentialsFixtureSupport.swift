import Foundation
import SwiftusCore
import SwiftusCredentials
import Testing

// MARK: - fixture 装载

/// S12/S15 fixture（{name, kind, cases}）。
struct CredentialsFixture {
    let name: String
    let kind: String
    let cases: [JSONValue]
}

enum CredentialsFixtureLoader {
    static func load(kind: String) -> [CredentialsFixture] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return ["s12", "s15"].flatMap { spec -> [CredentialsFixture] in
            let directory = root.appending(path: "spec/fixtures/\(spec)", directoryHint: .isDirectory)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path()) else {
                return []
            }
            return names
                .filter { $0.hasSuffix(".json") }
                .sorted()
                .compactMap { name -> CredentialsFixture? in
                    guard let object = try? JSONValue.parse(Data(contentsOf: directory.appending(path: name))).objectValue,
                          object["kind"]?.stringValue == kind else {
                        return nil
                    }
                    return CredentialsFixture(
                        name: object["name"]?.stringValue ?? name,
                        kind: kind,
                        cases: object["cases"]?.arrayValue ?? []
                    )
                }
        }
    }
}

// MARK: - 投影

/// 凭据表投影：键 → {value, expiresAt}（与导出器同款，键升序）。
@ContextTreeActor
func projectCredentialsTable(_ keys: [String], _ get: (String) -> Credential?) -> JSONValue {
    var object: [String: JSONValue] = [:]
    for key in keys.sorted() {
        guard let credential = get(key) else { continue }
        object[key] = .object([
            "value": .string(credential.value),
            "expiresAt": credential.expiresAt.map {
                .string($0.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            } ?? .null,
        ])
    }
    return .object(object)
}

@ContextTreeActor
func projectSnapshot(_ credentials: any Credentials) -> JSONValue {
    projectCredentialsTable(credentials.keys) { credentials.get($0) }
}

func errorCode(_ error: any Error) -> String {
    (error as? CredentialsException)?.code.rawValue ?? String(describing: type(of: error))
}

/// 深度比对投影：报出**首个差异路径**而不是整坨 JSON（fixtures 的期望体太大，
/// 整坨比对会把有效信息淹掉——本项目的历史教训）。
func expectSame(
    _ actual: [String: JSONValue],
    _ expected: [String: JSONValue],
    _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard actual != expected else { return }
    for (path, got, want) in firstDifferences(actual: .object(actual), expected: .object(expected)) {
        Issue.record(
            "「\(label)」\(path) 不一致\n  实际：\(brief(got))\n  期望：\(brief(want))",
            sourceLocation: sourceLocation
        )
    }
}

/// 深度求首个差异（最多报三条，够定位又不刷屏）。
private func firstDifferences(
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
        let child = path.isEmpty ? key : "\(path).\(key)"
        if found.count >= limit { return found }
        found += firstDifferences(
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
    if found.isEmpty {
        return [(path.isEmpty ? "(root)" : path, actual, expected)]
    }
    return found
}

/// 投影值的紧凑展示（长文本截断）。
func brief(_ value: JSONValue, limit: Int = 200) -> String {
    guard case let .string(text) = value else { return String(describing: value) }
    return text.count > limit ? String(text.prefix(limit)) + "…" : text
}

/// 把 Swift 侧的错误码投影到 fixture 用的拼写。
///
/// S12 §2 记录了一处有意偏离：Dart 的文件来源在内容非法 JSON 时抛无机器码的
/// `FormatException`，Swift 收敛为 `invalid-source` 以便按码路由。fixture 记的是
/// Dart 的实际行为，故比对时把 Swift 的码映射回 Dart 的拼写。
func normalizeThrownCode(_ code: String) -> String {
    code == CredentialsException.Code.invalidSource.rawValue ? "FormatException" : code
}

/// 错误码断言：某次调用应抛出的机器码（空串表示不应抛）。
@ContextTreeActor
func catchCode(_ body: () async throws -> Void) async -> String {
    do {
        try await body()
        return ""
    } catch {
        return errorCode(error)
    }
}
