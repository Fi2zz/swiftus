import Foundation
import SwiftusAgent
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM
import SwiftusTasks
import Testing

// MARK: - fixture 装载

/// S17 fixture（{name, kind, cases}）。
struct S17Fixture {
    let name: String
    let kind: String
    let cases: [JSONValue]
}

/// 从 spec/fixtures/s17 装载指定 kind 的 fixture。
enum S17FixtureLoader {
    static func load(kind: String) -> [S17Fixture] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "spec/fixtures/s17", directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path()) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .compactMap { name -> S17Fixture? in
                guard let root = try? JSONValue.parse(Data(contentsOf: directory.appending(path: name))).objectValue,
                      root["kind"]?.stringValue == kind else {
                    return nil
                }
                return S17Fixture(
                    name: root["name"]?.stringValue ?? name,
                    kind: kind,
                    cases: root["cases"]?.arrayValue ?? []
                )
            }
    }
}

// MARK: - 归一化与投影（与 tool/export_fixtures/export_s17.dart 同款）

/// 任务 id 归一化表：原始 id → `<task-N>`（按首次登记顺序）。
final class TaskIdNormalizer {
    private var mapping: [String: String] = [:]

    @discardableResult
    func callAsFunction(_ raw: String) -> String {
        if let existing = mapping[raw] { return existing }
        let next = "<task-\(mapping.count + 1)>"
        mapping[raw] = next
        return next
    }
}

/// 定值墙钟：任务 id 的微秒与各时间戳都取自它，duration 类断言因此确定。
let s17FixedInstant = Date(timeIntervalSince1970: 1_789_000_000)

func s17FixedClock() -> Date {
    s17FixedInstant
}

/// ISO8601 时刻序列化（UTC、小数秒），与 Task.jsonValue 同款。
func s17InstantString(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

/// 值的 JSON 形态名（无值时为 none）。
func s17ValueShape(_ value: JSONValue?) -> String {
    switch value {
    case nil, .some(.null): return "none"
    case .some(.string): return "string"
    case .some(.int), .some(.double): return "number"
    case .some(.bool): return "bool"
    case .some(.array): return "array"
    case .some(.object): return "object"
    }
}

/// 任务投影：id 归一化、时刻折叠为布尔；errorShape 只在 persisted 时给出。
@ContextTreeActor
func s17Project(_ task: Task, _ ids: TaskIdNormalizer, persisted: Bool = false) -> [String: JSONValue] {
    var out: [String: JSONValue] = [
        "id": .string(ids(task.id)),
        "kind": .string(task.kind.rawValue),
        "status": .string(task.status.rawValue),
        "description": .string(task.description),
        "hasStartedAt": .bool(task.startedAt != nil),
        "hasFinishedAt": .bool(task.finishedAt != nil),
        "parentTaskId": task.parentTaskId.map { JSONValue.string(ids($0)) } ?? .null,
        "metadata": .object(task.metadata),
        "hasResult": .bool(task.result != nil),
        "hasError": .bool(task.error != nil),
        "result": task.result ?? .null,
    ]
    if persisted {
        out["errorShape"] = .string(s17ValueShape(task.error))
    }
    return out
}

@ContextTreeActor
func s17ProjectTasks(_ tasks: [Task], _ ids: TaskIdNormalizer) -> [JSONValue] {
    tasks.map { .object(s17Project($0, ids)) }
}

/// 会话日志投影（task/changed 载荷的 errorShape 取持久化值）。
@ContextTreeActor
func s17ProjectLog(_ session: Session, _ ids: TaskIdNormalizer) throws -> [JSONValue] {
    try session.ownEvents.map { event in
        var entry: [String: JSONValue] = ["type": .string(event.type), "task": .null]
        if event.type == kTaskEvent, let data = event.data {
            entry["task"] = .object(s17Project(try Task(jsonValue: data), ids, persisted: true))
        }
        return .object(entry)
    }
}

@ContextTreeActor
func s17TelemetryNames(_ telemetry: InMemoryTelemetry) -> [JSONValue] {
    telemetry.recent.map { .string($0.name) }
}

/// 任务错误码（供 fixtures 的 codes 断言）。
func s17ErrorCode(_ error: any Error) -> String {
    (error as? TaskError)?.code ?? String(describing: type(of: error))
}

// MARK: - 测试替身

/// 带会话、埋点与定值时钟的任务中心（每个用例一份）。
@ContextTreeActor
final class TaskHarness {
    let session: Session
    let telemetry: InMemoryTelemetry
    let center: DefaultTaskCenter
    let ids = TaskIdNormalizer()
    /// 本份 harness 的定值时刻（构造时取一次，其后所有取样都返回它）。
    let instant: Date
    private(set) var changes: [Task] = []

    init(approval: (any Approval)? = nil) throws {
        session = try Session(id: "s1")
        telemetry = try InMemoryTelemetry()
        let instant = Date()
        self.instant = instant
        center = try DefaultTaskCenter(
            session: session,
            approval: approval,
            telemetry: telemetry,
            clock: { instant }
        )
    }

    /// 开始收集变更流（订阅在调用点同步建立，只收订阅之后的事件，对齐 broadcast 语义）。
    func startCollecting() {
        let stream = center.changes
        // 本 target 另有 Task 值类型，收集任务需写全 _Concurrency.Task。
        _Concurrency.Task { [self] in
            for await task in stream {
                changes.append(task)
            }
        }
    }

    /// 让变更收集器跑一轮（AsyncStream 缓冲由消费侧排空）。
    func drain() async {
        await _Concurrency.Task.yield()
        await _Concurrency.Task.yield()
    }

    /// 等到收集到的变更条数达到期望值（AsyncStream 订阅是异步落位的）。
    func waitForChanges(_ minimum: Int) async {
        for _ in 0..<200 {
            if changes.count >= minimum { return }
            try? await _Concurrency.Task.sleep(for: .milliseconds(2))
        }
    }
}

/// 记录式审批替身：捕获任务中心发出的取消确认请求。
@ContextTreeActor
final class RecordingApproval: Approval {
    private let approved: Bool
    private(set) var requests: [ApprovalRequest] = []

    init(_ approved: Bool) {
        self.approved = approved
    }

    func request(_ request: ApprovalRequest) async -> Bool {
        requests.append(request)
        return approved
    }

    var pending: AsyncStream<ApprovalRequest> {
        AsyncStream { $0.finish() }
    }
}

/// 脚本化模型（对齐 Dart 导出器替身）：按调用顺序返回预设结果，耗尽后重复最后一条。
@ContextTreeActor
final class S17ScriptedProvider: LlmProvider {
    private let script: [LlmResult]
    private var calls = 0

    init(_ script: [LlmResult]) {
        self.script = script
    }

    var name: String { "scripted" }

    func chat(_ request: LlmRequest) async throws -> LlmResult {
        calls += 1
        return script[min(calls - 1, script.count - 1)]
    }

    func chatStream(_ request: LlmRequest) -> AsyncThrowingStream<LlmStreamEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// 恒失败模型。
@ContextTreeActor
final class S17ThrowingProvider: LlmProvider {
    struct Unavailable: Error {}

    var name: String { "throwing" }

    func chat(_ request: LlmRequest) async throws -> LlmResult {
        throw Unavailable()
    }

    func chatStream(_ request: LlmRequest) -> AsyncThrowingStream<LlmStreamEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

func s17Text(_ content: String) -> LlmResult {
    LlmResult(content: content, provider: "scripted", model: "m")
}

/// 轮询等待任务落定（后台进程追踪是异步落定的）。
@ContextTreeActor
func s17WaitTerminal(_ center: any TaskCenter, _ id: String) async throws {
    for _ in 0..<400 {
        if let task = center.get(id), task.isTerminal { return }
        try await _Concurrency.Task.sleep(for: .milliseconds(5))
    }
    Issue.record("任务 \(id) 未在 2 秒内落定")
}
