import Foundation
import SwiftusAgent
import SwiftusCore
import SwiftusFoundation
import SwiftusSchedule
import SwiftusTasks
import Testing

/// 规格 S17 golden fixtures：任务词汇与 JSON / 状态机 / 任务树与取消 /
/// 会话恢复 / 模型侧工具 / 运行时接入。
@Suite("S17 golden fixtures")
struct S17FixtureTests {
    // MARK: 词汇与 JSON

    @Test("task-json", arguments: S17FixtureLoader.load(kind: "task-json"))
    @ContextTreeActor
    func taskJSON(_ fixture: S17Fixture) throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            switch caseItem["scenario"]?.stringValue {
            case "status-matrix":
                for entry in caseItem["cases"]?.arrayValue ?? [] {
                    let status = TaskStatus(rawValue: entry["status"]?.stringValue ?? "")
                    #expect(status != nil)
                    let task = Task(
                        id: "t1",
                        kind: .custom,
                        status: status ?? .pending,
                        description: "查机票",
                        createdAt: s17FixedInstant
                    )
                    #expect(task.isTerminal == (entry["isTerminal"] == .bool(true)))
                    #expect(task.isActive == (entry["isActive"] == .bool(true)))
                }
            case "copy-with":
                #expect(try copyWithCase() == expect)
            case "round-trip":
                let input = caseItem["input"] ?? .null
                let task = try Task(jsonValue: input)
                // 往返：再序列化再解一次必须完全一致。
                #expect(try Task(jsonValue: task.jsonValue) == task)
                #expect(try roundTripCase(of: task) == expect)
            case "tolerant-enums", "tolerant-instants":
                #expect(try tolerantCase(of: Task(jsonValue: caseItem["input"] ?? .null)) == expect)
            default:
                Issue.record("未知 scenario：\(caseItem["scenario"]?.stringValue ?? "")")
            }
        }
    }

    @ContextTreeActor
    private func copyWithCase() throws -> [String: JSONValue] {
        let base = Task(
            id: "t1",
            kind: .custom,
            status: .running,
            description: "查机票",
            createdAt: s17FixedInstant
        )
        let task = base.copyWith(
            startedAt: s17FixedInstant,
            result: .string("ok"),
            error: .string("oops")
        )
        let untouched = task.copyWith()
        let cleared = task.copyWith(result: .null, error: .null)
        return [
            "keptResult": untouched.result ?? .null,
            "keptError": untouched.error ?? .null,
            "keptStartedAt": .bool(untouched.startedAt != nil),
            "clearedResult": cleared.result ?? .null,
            "clearedError": cleared.error ?? .null,
            "originalResult": task.result ?? .null,
            "originalError": task.error ?? .null,
        ]
    }

    @ContextTreeActor
    private func roundTripCase(of task: Task) throws -> [String: JSONValue] {
        [
            "id": .string(task.id),
            "kind": .string(task.kind.rawValue),
            "status": .string(task.status.rawValue),
            "description": .string(task.description),
            "createdAt": .string(s17InstantString(task.createdAt)),
            "startedAt": task.startedAt.map { JSONValue.string(s17InstantString($0)) } ?? .null,
            "finishedAt": task.finishedAt.map { JSONValue.string(s17InstantString($0)) } ?? .null,
            "parentTaskId": task.parentTaskId.map { JSONValue.string($0) } ?? .null,
            "metadata": .object(task.metadata),
            "result": task.result ?? .null,
            "error": task.error ?? .null,
            "durationInSeconds": .int(Int64(task.duration(now: s17FixedInstant) ?? 0)),
            "isTerminal": .bool(task.isTerminal),
        ]
    }

    @ContextTreeActor
    private func tolerantCase(of task: Task) -> [String: JSONValue] {
        [
            "id": .string(task.id),
            "kind": .string(task.kind.rawValue),
            "status": .string(task.status.rawValue),
            "description": .string(task.description),
            "hasStartedAt": .bool(task.startedAt != nil),
            "hasFinishedAt": .bool(task.finishedAt != nil),
            "metadata": .object(task.metadata),
        ]
    }

    // MARK: 状态机

    @Test("state-machine", arguments: S17FixtureLoader.load(kind: "state-machine"))
    @ContextTreeActor
    func stateMachine(_ fixture: S17Fixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = try await runStateMachine(caseItem["scenario"]?.stringValue ?? "", ids: TaskIdNormalizer())
            #expect(actual == expect, "\(caseItem["label"]?.stringValue ?? "")")
        }
    }

    @ContextTreeActor
    private func runStateMachine(_ scenario: String, ids: TaskIdNormalizer) async throws -> [String: JSONValue] {
        let harness = try TaskHarness()
        let center = harness.center
        switch scenario {
        case "create":
            let task = try await center.create(
                kind: .custom,
                description: "查机票",
                parentTaskId: nil,
                metadata: ["goalId": .string("g1")]
            )
            return [
                "task": .object(s17Project(task, ids)),
                "all": .int(Int64(center.all.count)),
                "active": .int(Int64(center.active.count)),
                "log": .array(try s17ProjectLog(harness.session, ids)),
                "telemetry": .array(s17TelemetryNames(harness.telemetry)),
            ]
        case "running":
            let created = try await center.create(kind: .custom, description: "x", parentTaskId: nil, metadata: [:])
            let running = try await center.update(created.id, status: .running, result: nil, error: nil)
            let done = try await center.update(created.id, status: .completed, result: .string("ok"), error: nil)
            return [
                "running": .object(s17Project(running, ids)),
                "done": .object(s17Project(done, ids)),
                "durationInSeconds": .int(Int64(done.duration(now: s17FixedInstant) ?? 0)),
                "telemetry": .array(s17TelemetryNames(harness.telemetry)),
            ]
        case "pause-resume":
            let created = try await center.create(kind: .custom, description: "x", parentTaskId: nil, metadata: [:])
            _ = try await center.update(created.id, status: .running, result: nil, error: nil)
            let paused = try await center.update(created.id, status: .paused, result: nil, error: nil)
            let resumed = try await center.update(created.id, status: .running, result: nil, error: nil)
            return [
                "paused": .object(s17Project(paused, ids)),
                "resumed": .object(s17Project(resumed, ids)),
                "telemetry": .array(s17TelemetryNames(harness.telemetry)),
                "log": .array(try s17ProjectLog(harness.session, ids)),
            ]
        case "terminal-guard":
            let created = try await center.create(kind: .custom, description: "x", parentTaskId: nil, metadata: [:])
            _ = try await center.update(created.id, status: .completed, result: nil, error: nil)
            var codes: [JSONValue] = []
            do {
                _ = try await center.update(created.id, status: .running, result: nil, error: nil)
            } catch {
                codes.append(.string(s17ErrorCode(error)))
            }
            do {
                _ = try await center.update("nope", status: .running, result: nil, error: nil)
            } catch {
                codes.append(.string(s17ErrorCode(error)))
            }
            return ["codes": .array(codes)]
        case "no-change":
            let created = try await center.create(kind: .custom, description: "x", parentTaskId: nil, metadata: [:])
            _ = try await center.update(created.id, status: .pending, result: nil, error: nil)
            return [
                "logCount": .int(Int64(harness.session.ownEvents.count)),
                "telemetry": .array(s17TelemetryNames(harness.telemetry)),
                "task": .object(s17Project(center.get(created.id) ?? created, ids)),
            ]
        case "dispose":
            let created = try await center.create(kind: .custom, description: "x", parentTaskId: nil, metadata: [:])
            _ = try await center.update(created.id, status: .running, result: nil, error: nil)
            center.dispose()
            center.dispose()
            var codes: [JSONValue] = []
            do {
                _ = try await center.create(kind: .custom, description: "y", parentTaskId: nil, metadata: [:])
            } catch {
                codes.append(.string(s17ErrorCode(error)))
            }
            do {
                _ = try await center.update(created.id, status: .paused, result: nil, error: nil)
            } catch {
                codes.append(.string(s17ErrorCode(error)))
            }
            return [
                "codes": .array(codes),
                "telemetry": .array(s17TelemetryNames(harness.telemetry)),
            ]
        default:
            Issue.record("未知 scenario：\(scenario)")
            return [:]
        }
    }

    // MARK: 任务树与取消

    @Test("task-tree", arguments: S17FixtureLoader.load(kind: "task-tree"))
    @ContextTreeActor
    func taskTree(_ fixture: S17Fixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = try await runTaskTree(caseItem["scenario"]?.stringValue ?? "")
            #expect(actual == expect, "\(caseItem["label"]?.stringValue ?? "")")
        }
    }

    @ContextTreeActor
    private func runTaskTree(_ scenario: String) async throws -> [String: JSONValue] {
        switch scenario {
        case "tree-shape":
            let harness = try TaskHarness()
            let center = harness.center
            let ids = harness.ids
            let root = try await center.create(kind: .agentTurn, description: "root", parentTaskId: nil, metadata: [:])
            let childA = try await center.create(kind: .subAgent, description: "a", parentTaskId: root.id, metadata: [:])
            let childB = try await center.create(kind: .shell, description: "b", parentTaskId: root.id, metadata: [:])
            let grandChild = try await center.create(kind: .custom, description: "a1", parentTaskId: childA.id, metadata: [:])
            for task in [root, childA, childB, grandChild] { _ = ids(task.id) }
            return [
                "childrenOfRoot": .array(s17ProjectTasks(center.children(of: root.id), ids)),
                "childrenOfChildA": .array(s17ProjectTasks(center.children(of: childA.id), ids)),
                "subtreeOfRoot": .array(s17ProjectTasks(center.subtree(of: root.id), ids)),
                "subtreeOfMissing": .int(Int64(center.subtree(of: "ghost").count)),
                "ids": .array([root, childA, childB, grandChild].map { .string(ids($0.id)) }),
            ]
        case "cascade-cancel":
            let harness = try TaskHarness()
            let center = harness.center
            let ids = harness.ids
            let root = try await center.create(kind: .agentTurn, description: "root", parentTaskId: nil, metadata: [:])
            let child = try await center.create(kind: .subAgent, description: "child", parentTaskId: root.id, metadata: [:])
            let done = try await center.create(kind: .custom, description: "done", parentTaskId: root.id, metadata: [:])
            _ = try await center.update(done.id, status: .completed, result: nil, error: nil)
            for task in [root, child, done] { _ = ids(task.id) }
            var callbackRan = false
            center.registerCancel(child.id) { callbackRan = true }
            try await center.cancel(root.id)
            return [
                "statuses": .array([root, child, done].map { .string(center.get($0.id)?.status.rawValue ?? "") }),
                "root": .object(s17Project(center.get(root.id) ?? root, ids)),
                "child": .object(s17Project(center.get(child.id) ?? child, ids)),
                "callbackRan": .bool(callbackRan),
                "telemetry": .array(s17TelemetryNames(harness.telemetry)),
            ]
        case "shell-approval":
            let denial = RecordingApproval(false)
            let denied = try TaskHarness(approval: denial)
            let shell = try await denied.center.create(kind: .shell, description: "rm -rf build", parentTaskId: nil, metadata: [:])
            var deniedCode = ""
            do {
                try await denied.center.cancel(shell.id)
            } catch {
                deniedCode = s17ErrorCode(error)
            }
            let grant = RecordingApproval(true)
            let granted = try TaskHarness(approval: grant)
            let sleeper = try await granted.center.create(kind: .shell, description: "sleep 1", parentTaskId: nil, metadata: [:])
            let normalizedId = granted.ids(sleeper.id)
            try await granted.center.cancel(sleeper.id)
            let request = grant.requests.first
            return [
                "deniedCode": .string(deniedCode),
                "deniedStatus": .string(denied.center.get(shell.id)?.status.rawValue ?? ""),
                "deniedRequests": .int(Int64(denial.requests.count)),
                "grantedStatus": .string(granted.center.get(sleeper.id)?.status.rawValue ?? ""),
                "grantedRequests": .int(Int64(grant.requests.count)),
                "approvalRequest": .object([
                    "id": .string("cancel-\(normalizedId)"),
                    "toolName": .string(request?.toolName ?? ""),
                    "arguments": .object([
                        "id": .string(normalizedId),
                        "description": .string(request?.arguments["description"]?.stringValue ?? ""),
                    ]),
                    "description": .string(request?.description ?? ""),
                ]),
            ]
        case "non-shell":
            let denial = RecordingApproval(false)
            let harness = try TaskHarness(approval: denial)
            let custom = try await harness.center.create(kind: .custom, description: "x", parentTaskId: nil, metadata: [:])
            try await harness.center.cancel(custom.id)
            return [
                "status": .string(harness.center.get(custom.id)?.status.rawValue ?? ""),
                "requests": .int(Int64(denial.requests.count)),
            ]
        case "cancel-guards":
            let harness = try TaskHarness()
            let task = try await harness.center.create(kind: .custom, description: "x", parentTaskId: nil, metadata: [:])
            _ = try await harness.center.update(task.id, status: .completed, result: nil, error: nil)
            var codes: [JSONValue] = []
            do {
                try await harness.center.cancel(task.id)
            } catch {
                codes.append(.string(s17ErrorCode(error)))
            }
            do {
                try await harness.center.cancel("nope")
            } catch {
                codes.append(.string(s17ErrorCode(error)))
            }
            return ["codes": .array(codes)]
        default:
            Issue.record("未知 scenario：\(scenario)")
            return [:]
        }
    }

    // MARK: 会话恢复

    @Test("restore", arguments: S17FixtureLoader.load(kind: "restore"))
    @ContextTreeActor
    func restore(_ fixture: S17Fixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = try await runRestore(caseItem["scenario"]?.stringValue ?? "")
            #expect(actual == expect, "\(caseItem["label"]?.stringValue ?? "")")
        }
    }

    @ContextTreeActor
    private func s17Sample(id: String = "t1", status: TaskStatus = .pending) -> Task {
        Task(
            id: id,
            kind: .custom,
            status: status,
            description: "查机票",
            createdAt: Date(timeIntervalSince1970: 1_789_000_000)
        )
    }

    @ContextTreeActor
    private func runRestore(_ scenario: String) async throws -> [String: JSONValue] {
        let ids = TaskIdNormalizer()
        switch scenario {
        case "fold":
            let session = try Session(id: "s1")
            let first = s17Sample()
            let updated = first.copyWith(status: .completed)
            try session.append(kTaskEvent, data: first.jsonValue)
            try session.append("goal/changed", data: .object(["x": .int(1)]))
            try session.append(kTaskEvent, data: updated.jsonValue)
            try session.append(kTaskEvent, data: s17Sample(id: "t2").jsonValue)
            let restored = try restoreTaskState(session)
            return [
                "ids": .array(restored.map { .string($0.id) }),
                "normalized": .array(s17ProjectTasks(restored, ids)),
                "statuses": .array(restored.map { .string($0.status.rawValue) }),
            ]
        case "fork":
            let parent = try Session(id: "p1")
            try parent.append(kTaskEvent, data: s17Sample().jsonValue)
            let fork = try parent.fork(id: "f1")
            return [
                "forked": .int(Int64(try restoreTaskState(fork).count)),
                "parent": .int(Int64(try restoreTaskState(parent).count)),
            ]
        case "auto-restore":
            let session = try Session(id: "s1")
            let created = Date(timeIntervalSince1970: 1_789_000_000)
            let stale = Task(
                id: "stale-1",
                kind: .shell,
                status: .running,
                description: "sleep 100",
                createdAt: created,
                startedAt: created
            )
            let done = Task(
                id: "done-1",
                kind: .custom,
                status: .completed,
                description: "x",
                createdAt: created
            )
            try session.append(kTaskEvent, data: stale.jsonValue)
            try session.append(kTaskEvent, data: done.jsonValue)
            let telemetry = try InMemoryTelemetry()
            let center = try DefaultTaskCenter(session: session, telemetry: telemetry, clock: s17FixedClock)
            let restoredStale = center.get("stale-1") ?? stale
            return [
                "stale": .object(s17Project(restoredStale, ids)),
                "done": .object(s17Project(center.get("done-1") ?? done, ids)),
                "staleErrorIsStaleReason": .bool(restoredStale.error == .string(kTaskStaleReason)),
                "log": .array(try s17ProjectLog(session, ids)),
                "telemetry": .array(s17TelemetryNames(telemetry)),
                "active": .int(Int64(center.active.count)),
            ]
        default:
            Issue.record("未知 scenario：\(scenario)")
            return [:]
        }
    }

    // MARK: 模型侧工具

    @Test("task-tools", arguments: S17FixtureLoader.load(kind: "task-tools"))
    @ContextTreeActor
    func taskTools(_ fixture: S17Fixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = try await runTaskTools(caseItem)
            #expect(actual == expect, "\(caseItem["label"]?.stringValue ?? "")")
        }
    }

    @ContextTreeActor
    private func runTaskTools(_ caseItem: JSONValue) async throws -> [String: JSONValue] {
        switch caseItem["scenario"]?.stringValue {
        case "describe":
            let created = Date(timeIntervalSince1970: 1_789_000_000)
            func build(
                id: String,
                kind: TaskKind,
                status: TaskStatus,
                description: String,
                ran: TimeInterval?,
                result: JSONValue? = nil
            ) -> Task {
                Task(
                    id: id,
                    kind: kind,
                    status: status,
                    description: description,
                    createdAt: created,
                    startedAt: ran == nil ? nil : created,
                    finishedAt: ran == nil ? nil : created.addingTimeInterval(ran ?? 0),
                    result: result
                )
            }
            let tasks = [
                build(id: "t1", kind: .agentTurn, status: .running, description: "查机票", ran: 200),
                build(id: "t2", kind: .shell, status: .completed, description: "npm test", ran: 42, result: .object(["exitCode": .int(0)])),
                build(id: "t3", kind: .subAgent, status: .failed, description: "盯快递", ran: nil),
            ]
            return [
                "empty": .string(describeTasks([])),
                "text": .string(describeTasks(tasks, now: created)),
            ]
        case "list":
            let harness = try TaskHarness()
            let center = harness.center
            let running = try await center.create(kind: .agentTurn, description: "查机票", parentTaskId: nil, metadata: [:])
            _ = try await center.update(running.id, status: .running, result: nil, error: nil)
            let child = try await center.create(kind: .subAgent, description: "盯快递", parentTaskId: running.id, metadata: [:])
            let shell = try await center.create(kind: .shell, description: "npm test", parentTaskId: nil, metadata: [:])
            _ = try await center.update(shell.id, status: .completed, result: nil, error: nil)
            // 与导出器同序预登记：`<task-1>` 即第一个创建的任务。
            let created = [running, child, shell]
            for task in created { _ = harness.ids(task.id) }
            var arguments: [String: JSONValue] = [:]
            for (key, value) in caseItem["arguments"]?.objectValue ?? [:] {
                if key == "parent_id", let normalized = value.stringValue,
                   let index = Int(normalized.dropFirst("<task-".count).dropLast()),
                   created.indices.contains(index - 1) {
                    arguments[key] = .string(created[index - 1].id)
                } else {
                    arguments[key] = value
                }
            }
            let result = try await ListTasksTool(taskCenter: center).call(ToolContext(
                ToolCall(name: kListTasksToolName, arguments: arguments)
            ))
            return [
                "content": .string(result.content),
                "failed": .bool(result.failed),
            ]
        case "cancel-ok":
            let harness = try TaskHarness()
            let running = try await harness.center.create(kind: .agentTurn, description: "查机票", parentTaskId: nil, metadata: [:])
            _ = try await harness.center.update(running.id, status: .running, result: nil, error: nil)
            let result = try await CancelTaskTool(taskCenter: harness.center).call(ToolContext(
                ToolCall(name: kCancelTasksToolName, arguments: ["id": .string(running.id)])
            ))
            return [
                "content": .string(result.content),
                "isError": .bool(result.failed),
                "status": .string(harness.center.get(running.id)?.status.rawValue ?? ""),
            ]
        case "cancel-missing":
            let harness = try TaskHarness()
            let result = try await CancelTaskTool(taskCenter: harness.center).call(ToolContext(
                ToolCall(name: kCancelTasksToolName, arguments: ["id": .string("nope")])
            ))
            return [
                "content": .string(result.content),
                "isError": .bool(result.failed),
                "code": .string(result.error?.code ?? ""),
            ]
        case "cancel-denied":
            let harness = try TaskHarness(approval: RecordingApproval(false))
            let shell = try await harness.center.create(kind: .shell, description: "sleep 99", parentTaskId: nil, metadata: [:])
            let result = try await CancelTaskTool(taskCenter: harness.center).call(ToolContext(
                ToolCall(name: kCancelTasksToolName, arguments: ["id": .string(shell.id)])
            ))
            return [
                "content": .string(result.content),
                "isError": .bool(result.failed),
                "code": .string(result.error?.code ?? ""),
                "status": .string(harness.center.get(shell.id)?.status.rawValue ?? ""),
            ]
        default:
            Issue.record("未知 scenario：\(caseItem["scenario"]?.stringValue ?? "")")
            return [:]
        }
    }

    // MARK: 运行时接入

    @Test("tracking-flow", arguments: S17FixtureLoader.load(kind: "tracking-flow"))
    @ContextTreeActor
    func trackingFlow(_ fixture: S17Fixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = try await runTrackingFlow(caseItem)
            #expect(actual == expect, "\(caseItem["label"]?.stringValue ?? "")")
        }
    }

    @ContextTreeActor
    private func runTrackingFlow(_ caseItem: JSONValue) async throws -> [String: JSONValue] {
        let scenario = caseItem["scenario"]?.stringValue ?? ""
        let harness = try TaskHarness()
        let center = harness.center
        let ids = harness.ids
        switch scenario {
        case "turn-ok":
            let tracking = TaskTracking(tasks: center)
            let loop = AgentLoop(llm: S17ScriptedProvider([s17Text("你好")]), tools: ToolRegistry())
            loop.turnTracker = tracking
            let turn = try await loop.run("在吗")
            return [
                "reply": .string(turn.reply),
                "task": .object(s17Project(center.all.first ?? s17Sample(), ids)),
                "currentTurnTaskId": tracking.currentTurnTaskId.map { JSONValue.string($0) } ?? .null,
                "telemetry": .array(s17TelemetryNames(harness.telemetry)),
            ]
        case "turn-failed":
            let tracking = TaskTracking(tasks: center)
            let closed = try Session(id: "closed")
            closed.close()
            var config = AgentLoop.Config()
            config.session = closed
            let loop = AgentLoop(llm: S17ScriptedProvider([s17Text("x")]), tools: ToolRegistry(), config: config)
            loop.turnTracker = tracking
            var threw = false
            do {
                _ = try await loop.run("hi")
            } catch {
                threw = true
            }
            return [
                "threw": .bool(threw),
                "task": .object(s17Project(center.all.first ?? s17Sample(), ids)),
                "log": .array(try s17ProjectLog(harness.session, ids)),
                "telemetry": .array(s17TelemetryNames(harness.telemetry)),
            ]
        case "spawn-ok":
            let host = Context.root()
            let registry = ToolRegistry()
            try registry.register(SpawnAgentTool(
                host: host,
                llm: S17ScriptedProvider([s17Text("结论：最低 720 元")]),
                tools: registry
            ))
            let tracking = TaskTracking(tasks: center)
            _ = registry.use(tracking.spawnAgentMiddleware)
            try await tracking.beginTurn("查机票")
            let result = await registry.call(ToolCall(
                name: kSpawnAgentToolName,
                arguments: ["task": .string("查明天机票"), "max_rounds": .int(3)]
            ))
            try await tracking.endTurn(result: .string(result.content), error: nil)
            host.dispose()
            let turn = center.all.first { $0.kind == .agentTurn } ?? s17Sample()
            let sub = center.all.first { $0.kind == .subAgent } ?? s17Sample()
            _ = ids(turn.id)
            _ = ids(sub.id)
            return [
                "toolIsError": .bool(result.failed),
                "turn": .object(s17Project(turn, ids)),
                "sub": .object(s17Project(sub, ids)),
                "telemetry": .array(s17TelemetryNames(harness.telemetry)),
            ]
        case "spawn-failed":
            let host = Context.root()
            let registry = ToolRegistry()
            try registry.register(SpawnAgentTool(
                host: host,
                llm: S17ThrowingProvider(),
                tools: registry
            ))
            let tracking = TaskTracking(tasks: center)
            _ = registry.use(tracking.spawnAgentMiddleware)
            let result = await registry.call(ToolCall(
                name: kSpawnAgentToolName,
                arguments: ["task": .string("必失败")]
            ))
            host.dispose()
            let sub = center.all.first { $0.kind == .subAgent } ?? s17Sample()
            let errorText = sub.error?.stringValue ?? ""
            return [
                "toolIsError": .bool(result.failed),
                "sub": .object(s17Project(sub, ids)),
                "errorContainsSubFailure": .bool(errorText.contains("子 Agent 失败")),
            ]
        case "schedule-delivery":
            var calls = 0
            let deliver = trackScheduleDelivery(center) { _ in
                calls += 1
                return calls == 1
            }
            let first = try await deliver("该喝水了")
            let second = try await deliver("该喝水了")
            return [
                "delivered": .array([.bool(first), .bool(second)]),
                "tasks": .array(s17ProjectTasks(center.all.filter { $0.kind == .schedule }, ids)),
            ]
        case "shell-foreground":
            let command = caseItem["command"]?.stringValue ?? "echo hello"
            // 真跑本地执行器（S18），不替身：命令、退出码与任务载荷都由真实进程产出。
            let executor = TrackingTaskShellExecutor(inner: LocalShellExecutor(), tasks: center)
            let result = try await executor.run(executor.resolve(ShellExecRequest(command: command)))
            return [
                "exitCode": result.exitCode.map { JSONValue.int(Int64($0)) } ?? .null,
                "task": .object(s17Project(center.all.first ?? s17Sample(), ids)),
            ]
        case "shell-killed":
            let command = caseItem["command"]?.stringValue ?? "sleep 30"
            let executor = TrackingTaskShellExecutor(inner: LocalShellExecutor(), tasks: center)
            let process = try await executor.start(executor.resolve(ShellExecRequest(command: command)))
            _ = process.kill()
            await process.done.value
            let task = center.all.first ?? s17Sample()
            try await s17WaitTerminal(center, task.id)
            let settled = center.get(task.id) ?? task
            return [
                "kind": .string(settled.kind.rawValue),
                "status": .string(settled.status.rawValue),
                "description": .string(settled.description),
                "metadata": .object(settled.metadata),
                "hasFinishedAt": .bool(settled.finishedAt != nil),
                "resultKeys": .array(settled.result?.objectValue.map { $0.keys.sorted().map { JSONValue.string($0) } } ?? []),
            ]
        default:
            Issue.record("未知 scenario：\(scenario)")
            return [:]
        }
    }
}
