import Foundation
import SwiftusCore
import SwiftusCron
import Testing

/// S9 fixture（{name, kind, localZone, now, startedAt?, cases}）。
struct S9Fixture {
    let name: String
    let kind: String
    /// 规则语义使用的本地时区（导出器钉死 UTC，见 exporter 的时区守卫）。
    let zone: TimeZone
    /// fixture 顶层固定的墙钟采样。
    let now: Date
    /// 服务装配时刻（every / cron 锚点）。
    let startedAt: Date
    let raw: JSONValue
    let cases: [JSONValue]
}

enum S9FixtureLoader {
    /// 全部 kind（装载自检与参数化共用）。
    static let kinds = [
        "cron-parse", "cron-rules", "cron-registry", "cron-history",
        "cron-message", "cron-runtime", "cron-tools",
    ]

    /// fixture 名（按 kind 过滤、排序）——参数化用例只拿名字，
    /// 免得 swift-testing 失败时把整份 fixture 打进输出。
    static func names(kind: String) -> [String] {
        load(kind: kind).map(\.name)
    }

    /// 全部 fixture（一次性读目录）。
    static func loadAll() -> [S9Fixture] {
        kinds.flatMap { load(kind: $0) }
    }

    /// 按名字取一份 fixture。
    static func load(named name: String) -> S9Fixture? {
        loadAll().first { $0.name == name }
    }

    /// 按 kind 装载 fixture（spec/fixtures/s9）。
    ///
    /// 装载不到任何 fixture 时调用方必须显式失败：参数化用例拿到空集合会被静默
    /// 跳过，于是「零 fixture 全绿」看起来像通过（本项目已吃过两次，见 HANDOFF）。
    static func load(kind: String) -> [S9Fixture] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "spec/fixtures/s9", directoryHint: .isDirectory)
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
                return S9Fixture(
                    name: root["name"]?.stringValue ?? name,
                    kind: kind,
                    zone: TimeZone(identifier: root["localZone"]?.stringValue ?? "UTC") ?? .current,
                    now: cronFixtureInstant(root["now"]),
                    startedAt: cronFixtureOptionalInstant(root["startedAt"]) ?? cronFixtureInstant(root["now"]),
                    raw: .object(root),
                    cases: root["cases"]?.arrayValue ?? []
                )
            }
    }
}

/// fixture 里的时刻（缺键取纪元，保证顶层字段不必处理可选）。
func cronFixtureInstant(_ value: JSONValue?) -> Date {
    value?.stringValue.flatMap(CronInstant.parse) ?? Date(timeIntervalSince1970: 0)
}

/// fixture 里的**可选**时刻（缺键即 nil——别拿纪元兜底，运行戳缺省是「没运行过」）。
func cronFixtureOptionalInstant(_ value: JSONValue?) -> Date? {
    value?.stringValue.flatMap(CronInstant.parse)
}

/// 任务描述 → 内部记录（与导出器 `_taskSpec` 同形）。
func cronFixtureTask(_ spec: [String: JSONValue], origin: CronTaskOrigin = .dynamic) -> CronTask {
    let task = CronTask(
        id: spec["id"]?.stringValue ?? "",
        prompt: spec["prompt"]?.stringValue ?? "做点什么",
        at: spec["at"]?.stringValue,
        every: cronFixtureNumber(spec["every"]),
        daily: spec["daily"]?.stringValue,
        cron: spec["cron"]?.stringValue,
        sessionId: spec["sessionId"]?.stringValue,
        enabled: { if case .bool(false) = spec["enabled"] { return false }; return true }(),
        origin: origin
    )
    if case .some(.bool(let flag)) = spec["enabledOverride"] {
        task.enabledOverride = flag
    }
    task.lastRunAt = cronFixtureOptionalInstant(spec["lastRunAt"])
    task.firedAt = cronFixtureOptionalInstant(spec["firedAt"])
    task.cronParsed = task.cron.flatMap { parseCronExpression($0) }
    return task
}

private func cronFixtureNumber(_ value: JSONValue?) -> Double? {
    switch value {
    case .some(.int(let raw)): return Double(raw)
    case .some(.double(let raw)): return raw
    default: return nil
    }
}

// MARK: - 内存存储

/// 测试用存储：保留最后一次快照与历史，行为与 JSON 后端的快照语义一致。
final class MemoryCronStorage: CronStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = CronStorageSnapshot.empty
    private var history: [JSONValue] = []
    private var taskSaves = 0
    private var historySaves = 0

    var savedTasks: [[String: JSONValue]] {
        lock.lock(); defer { lock.unlock() }
        return snapshot.dynamicTasks
    }

    var saveTaskCount: Int {
        lock.lock(); defer { lock.unlock() }
        return taskSaves
    }

    var saveHistoryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return historySaves
    }

    var savedHistory: [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return history
    }

    /// 预置快照（模拟磁盘上已有的持久状态）。
    func seed(_ snapshot: CronStorageSnapshot) {
        lock.lock(); defer { lock.unlock() }
        self.snapshot = snapshot
    }

    /// 预置历史（模拟磁盘上已有一条旧账本）。
    func seedHistory(_ records: [JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        history = records
    }

    func loadTasks() -> CronStorageSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    func saveTasks(
        tasks: [[String: JSONValue]],
        runStamps: [String: CronRunStamp],
        overrides: [String: Bool]
    ) {
        lock.lock(); defer { lock.unlock() }
        taskSaves += 1
        snapshot = CronStorageSnapshot(
            dynamicTasks: tasks,
            runStamps: runStamps,
            overrides: overrides
        )
    }

    func loadHistory() -> [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return history
    }

    func saveHistory(_ records: [JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        historySaves += 1
        history = records
    }
}

// MARK: - 投影与比对

/// 执行一步：成功给投影，失败给**裸错误码**（与 run-now 场景的期望形态一致）。
@ContextTreeActor
func cronFixtureCode(_ body: () async throws -> Void) async -> JSONValue {
    do {
        try await body()
        return .string("ran")
    } catch let error as CronException {
        return .string(error.code.rawValue)
    } catch {
        return .string(String(describing: type(of: error)))
    }
}

/// 异常 → `{error: 错误码}`（不抛到测试外）。
@ContextTreeActor
func cronFixtureAttempt(_ body: () async throws -> JSONValue) async -> JSONValue {
    do {
        return try await body()
    } catch let error as CronException {
        return .object(["error": .string(error.code.rawValue)])
    } catch {
        return .object(["error": .string(String(describing: type(of: error)))])
    }
}

/// 断言计数：每个 fixture 至少要比对一次。
///
/// 参数化用例里「一条都没比」（用例没跑到、投影键全被裁掉、解析失败走了
/// `continue`）都会表现为全绿——vacuously passing 的 fixture 比没有 fixture 更危险，
/// 故每个运行器结尾都要断言计数非零。
final class CronAssertionCounter: @unchecked Sendable {
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

/// 深度求首个差异（最多三条），避免整坨 JSON 的失败输出淹没有效信息。
func cronExpectSame(
    _ actual: [String: JSONValue],
    _ expected: [String: JSONValue],
    _ label: String,
    counter: CronAssertionCounter? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    counter?.hit()
    guard actual != expected else { return }
    for (path, got, want) in cronDifferences(actual: .object(actual), expected: .object(expected)) {
        Issue.record(
            "「\(label)」\(path) 不一致\n  实际：\(cronBrief(got))\n  期望：\(cronBrief(want))",
            sourceLocation: sourceLocation
        )
    }
}

private func cronDifferences(
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
        found += cronDifferences(
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

private func cronBrief(_ value: JSONValue, limit: Int = 200) -> String {
    guard case let .string(text) = value else { return String(describing: value) }
    return text.count > limit ? String(text.prefix(limit)) + "…" : text
}
