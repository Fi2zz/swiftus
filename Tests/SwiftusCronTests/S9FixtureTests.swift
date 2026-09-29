import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusCron
import Testing

/// 规格 S9 golden fixtures：表达式引擎（cron-parse）、规则与到期判定（cron-rules）、
/// 注册表（cron-registry）、历史账本（cron-history）、视图与 framing（cron-message）、
/// 运行时（cron-runtime）、工具结果（cron-tools）。
@Suite("S9 golden fixtures")
struct S9FixtureTests {

    // MARK: cron-parse · 表达式引擎

    @Test("cron-parse", arguments: S9FixtureLoader.names(kind: "cron-parse"))
    @ContextTreeActor
    func cronParse(_ name: String) async throws {
        let fixture = try #require(S9FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = CronAssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let label = caseItem["label"]?.stringValue ?? ""
            let inputs = caseItem["input"]?.arrayValue ?? []
            let expects = caseItem["expect"]?.arrayValue ?? []
            #expect(inputs.count == expects.count, "「\(label)」输入与期望数量应一致")

            switch scenario {
            case "parse":
                for (input, expect) in zip(inputs, expects) {
                    let expression = input.stringValue ?? ""
                    let parsed = parseCronExpression(expression)
                    // 合法表达式投影四件套，非法表达式只投影 `parsed`——投影键以
                    // fixture 的 expect 为准，两端不必各自维护一份键清单。
                    let full: [String: JSONValue] = [
                        "parsed": .bool(parsed != nil),
                        "fields": cronFixtureFields(parsed),
                        "domStar": parsed.map { .bool($0.domStar) } ?? .null,
                        "dowStar": parsed.map { .bool($0.dowStar) } ?? .null,
                    ]
                    let expect = expect.objectValue ?? [:]
                    cronExpectSame(cronProjectKeys(full, expect), expect, "parse \(expression)", counter: counter)
                }
            case "match":
                for (input, expect) in zip(inputs, expects) {
                    let expression = input["expression"]?.stringValue ?? ""
                    let local = input["local"]?.stringValue ?? ""
                    guard let parsed = parseCronExpression(expression) else { continue }
                    // fixture 的 `local` 是**本地墙钟**串，按 fixture 声明的时区解释。
                    let localInstant = cronFixtureLocal(local, zone: fixture.zone)
                    let actual: [String: JSONValue] = [
                        "matches": .bool(cronMatches(parsed, localInstant, zone: fixture.zone)),
                    ]
                    cronExpectSame(actual, expect.objectValue ?? [:], "match \(expression) @ \(local)", counter: counter)
                }
            case "next-slot":
                for (input, expect) in zip(inputs, expects) {
                    let expression = input["expression"]?.stringValue ?? ""
                    let after = cronFixtureInstant(input["after"])
                    let next = parseCronExpression(expression).flatMap {
                        nextCronSlot($0, after: after, zone: fixture.zone)
                    }
                    let actual: [String: JSONValue] = [
                        "next": CronInstant.format(next),
                    ]
                    cronExpectSame(
                        actual,
                        expect.objectValue ?? [:],
                        "next \(expression) after \(input["after"]?.stringValue ?? "")",
                        counter: counter
                    )
                }
            default:
                Issue.record("未知 scenario：\(scenario)")
            }
        }
        // 至少比对过一次（vacuously passing 的 fixture 比没有 fixture 更危险）。
        #expect(counter.total > 0, "\(name) 没有产生任何比对")

    }

    // MARK: cron-rules · 校验与到期判定

    @Test("cron-rules", arguments: S9FixtureLoader.names(kind: "cron-rules"))
    @ContextTreeActor
    func cronRules(_ name: String) async throws {
        let fixture = try #require(S9FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = CronAssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let label = caseItem["label"]?.stringValue ?? ""
            switch scenario {
            case "validate":
                let messages = caseItem["expect"]?.objectValue?["messages"]?.arrayValue ?? []
                for (input, expect) in zip(caseItem["input"]?.arrayValue ?? [], messages) {
                    let raw = input.objectValue ?? [:]
                    let actual = validateCronTaskInput(CronTaskInput(raw))
                    let want = expect.stringValue
                    if let want {
                        #expect(actual == want, "校验消息不一致：输入 \(raw)")
                    } else {
                        #expect(actual == nil, "校验应通过：输入 \(raw)")
                    }
                }
            case "due":
                let specs = caseItem["input"]?.arrayValue ?? []
                let rows = caseItem["expect"]?.arrayValue ?? []
                for (spec, row) in zip(specs, rows) {
                    let task = cronFixtureTask(spec.objectValue ?? [:])
                    let expect = row.objectValue ?? [:]
                    var actual: [String: JSONValue] = [
                        "label": row["label"] ?? .null,
                        "due": CronInstant.format(
                            cronDueSlot(of: task, now: fixture.now, startedAt: fixture.startedAt, zone: fixture.zone)
                        ),
                        "nextRunAt": buildCronTaskView(
                            task, now: fixture.now, startedAt: fixture.startedAt, zone: fixture.zone
                        ).json["nextRunAt"] ?? .null,
                    ]
                    actual["label"] = expect["label"] ?? .null
                    cronExpectSame(actual, expect, row["label"]?.stringValue ?? label, counter: counter)
                }
            case "id-gen":
                let expect = caseItem["expect"]?.objectValue ?? [:]
                let instant = cronFixtureInstant(caseItem["input"]?["now"])
                let suffixes = caseItem["input"]?["randomSuffixes"]?.arrayValue ?? []
                let ids = suffixes.map { generateCronTaskId(now: instant, randomSuffix: Int($0.intValue ?? 0)) }
                let actual: [String: JSONValue] = [
                    "shapeMatches": .bool(ids.first.map { $0.wholeMatch(of: /^task-[0-9a-z]+-[0-9a-z]{4}$/) != nil } ?? false),
                    "distinctWithSameInstant": .bool(Set(ids).count == ids.count && ids.count > 1),
                ]
                cronExpectSame(actual, expect, label, counter: counter)
            default:
                Issue.record("未知 scenario：\(scenario)")
            }
        }
        // 至少比对过一次（vacuously passing 的 fixture 比没有 fixture 更危险）。
        #expect(counter.total > 0, "\(name) 没有产生任何比对")

    }

    // MARK: cron-registry · 装配与增删改

    @Test("cron-registry", arguments: S9FixtureLoader.names(kind: "cron-registry"))
    @ContextTreeActor
    func cronRegistry(_ name: String) async throws {
        let fixture = try #require(S9FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = CronAssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let label = caseItem["label"]?.stringValue ?? ""
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let input = caseItem["input"]?.objectValue ?? [:]
            let now = fixture.now

            switch scenario {
            case "boot":
                let storage = MemoryCronStorage()
                var stamps: [String: CronRunStamp] = [:]
                for (id, value) in input["runStamps"]?.objectValue ?? [:] {
                    stamps[id] = CronRunStamp(lastRunAt: cronFixtureInstant(value["lastRunAt"]))
                }
                var overrides: [String: Bool] = [:]
                for (id, value) in input["overrides"]?.objectValue ?? [:] {
                    if case .bool(let flag) = value { overrides[id] = flag }
                }
                storage.seed(CronStorageSnapshot(
                    dynamicTasks: input["storedTasks"]?.arrayValue?.compactMap(\.objectValue) ?? [],
                    runStamps: stamps,
                    overrides: overrides
                ))
                let warnings = WarningBox()
                let service = CronService(
                    storage: storage,
                    configTasks: input["configTasks"]?.arrayValue?.compactMap(\.objectValue) ?? [],
                    timeZone: fixture.zone,
                    clock: { now },
                    onWarning: { warnings.append($0) },
                    entropy: { _ in 1 }
                )
                let actual: [String: JSONValue] = [
                    "ids": .array(service.tasks.map { .string($0.id) }),
                    "warnings": .int(Int64(warnings.all.count)),
                    "keptLastRunAt": CronInstant.format(service.findTask("kept")?.lastRunAt),
                    "cfgOverride": service.findTask("cfg")?.enabledOverride.map { .bool($0) } ?? .null,
                    "keptOrigin": service.findTask("kept").map { .string($0.origin.rawValue) } ?? .null,
                    "cfgOrigin": service.findTask("cfg").map { .string($0.origin.rawValue) } ?? .null,
                ]
                cronExpectSame(actual, expect, label, counter: counter)

            case "crud", "persistence":
                let ops = input["ops"]?.arrayValue ?? []
                let storage = MemoryCronStorage()
                let service = CronService(
                    storage: storage,
                    configTasks: input["configTasks"]?.arrayValue?.compactMap(\.objectValue) ?? [],
                    timeZone: fixture.zone,
                    clock: { now },
                    // 自动生成的 id 需确定：后缀固定 1。
                    entropy: { _ in 1 }
                )
                var projections: [String: JSONValue] = [:]
                for step in ops {
                    guard let row = step.objectValue else { continue }
                    let op = row["op"]?.stringValue ?? ""
                    let opLabel = row["label"]?.stringValue ?? op
                    projections[opLabel] = await cronFixtureAttempt {
                        switch op {
                        case "add":
                            let view = try service.addDynamicTask(row["input"]?.objectValue ?? [:])
                            if row["projectGenerated"] != nil {
                                return .object([
                                    "shape": .bool(view.id.wholeMatch(of: /^task-[0-9a-z]+-[0-9a-z]{4}$/) != nil),
                                    "boundSession": view.sessionId.map { .string($0) } ?? .null,
                                    "viewSchedule": .object(view.schedule),
                                ])
                            }
                            return .object(view.json)
                        case "update":
                            let view = try service.updateDynamicTask(
                                row["id"]?.stringValue ?? "",
                                row["patch"]?.objectValue ?? [:]
                            )
                            return .object(view.json)
                        case "remove":
                            try service.removeDynamicTask(row["id"]?.stringValue ?? "")
                            return .string("removed")
                        case "setEnabled":
                            let view = try service.setEnabled(
                                row["id"]?.stringValue ?? "",
                                { if case .bool(let flag) = row["enabled"] { return flag }; return true }()
                            )
                            return .object(view.json)
                        default:
                            return .string("unknown-op")
                        }
                    }
                }

                if scenario == "crud" {
                    var actual = projections
                    actual["remainingCount"] = .int(Int64(service.tasks.count))
                    actual["remainingAllGenerated"] = .bool(
                        service.tasks.allSatisfy { $0.id.wholeMatch(of: /^task-[0-9a-z]+-[0-9a-z]{4}$/) != nil }
                    )
                    // 期望值里 deleteDynamic 那步的投影是 'removed'，键名对齐即可。
                    cronExpectSame(actual, expect, label, counter: counter)
                } else {
                    let keys: [JSONValue] = storage.savedTasks.map { task in
                        .array(task.keys.sorted().map { JSONValue.string($0) })
                    }
                    let actual: [String: JSONValue] = [
                        "savedTaskKeys": keys.isEmpty ? .array([]) : .array(keys),
                        "savedCount": .int(Int64(storage.savedTasks.count)),
                    ]
                    cronExpectSame(actual, expect, label, counter: counter)
                }

            default:
                Issue.record("未知 scenario：\(scenario)")
            }
        }
        // 至少比对过一次（vacuously passing 的 fixture 比没有 fixture 更危险）。
        #expect(counter.total > 0, "\(name) 没有产生任何比对")

    }

    // MARK: cron-history · 账本

    @Test("cron-history", arguments: S9FixtureLoader.names(kind: "cron-history"))
    @ContextTreeActor
    func cronHistory(_ name: String) async throws {
        let fixture = try #require(S9FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = CronAssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let label = caseItem["label"]?.stringValue ?? ""
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let input = caseItem["input"]?.objectValue ?? [:]
            let now = fixture.now
            let taskId = input["taskId"]?.stringValue ?? "t1"
            let slot = cronFixtureInstant(input["slot"])
            let firedAt = cronFixtureInstant(input["firedAt"])
            let excerptLength = Int(input["excerptLength"]?.intValue ?? 0)
            let missingId = input["missingRecordId"]?.stringValue ?? "run-999-zz"

            let service = CronService(
                storage: MemoryCronStorage(),
                timeZone: fixture.zone,
                clock: { now },
                entropy: { _ in 1 }
            )
            let first = service.allocateRecordRef(now)
            service.releaseRecordRef(first)
            let second = service.allocateRecordRef(now)
            let committed = service.commitFire(ref: second, taskId: taskId, slot: slot, firedAt: firedAt)
            let finished = service.finishRun(committed.id, ok: true, excerpt: String(repeating: "x", count: excerptLength))
            let failed = service.finishRun(committed.id, ok: false)
            let missing = service.finishRun(missingId, ok: true)

            switch scenario {
            case "ledger":
                let actual: [String: JSONValue] = [
                    "firstSeqReleased": .int(Int64(first.seq)),
                    "secondSeq": .int(Int64(second.seq)),
                    "recordIdShape": .bool(committed.id.wholeMatch(of: /^run-\d+-[0-9a-z]+$/) != nil),
                    "record": .object(committed.json),
                    "finishedStatus": finished.map { .string($0.status.rawValue) } ?? .null,
                    "excerptLength": finished?.excerpt.map { .int(Int64($0.count)) } ?? .null,
                    // 第二次 finish 命中同一条记录：状态被覆盖为 failed（不是「未知 id」）。
                    "failedStatusOnMissing": .string(failed?.status.rawValue ?? "null"),
                    "missingRecord": missing == nil ? .string("null") : .string("record"),
                ]
                cronExpectSame(actual, expect, label, counter: counter)
            case "limit":
                // limit 缺省是 JSON null，与「给了一个数」区分开。
                let limits: [Int?] = (input["listLimits"]?.arrayValue ?? []).map { value in
                    if case .null = value { return nil }
                    return Int(value.intValue ?? 0)
                }
                let caps: [JSONValue] = limits.map { limit in
                    .int(Int64(service.listHistory(limit: limit).count))
                }
                let actual: [String: JSONValue] = ["caps": .array(caps)]
                cronExpectSame(actual, expect, label, counter: counter)
            default:
                Issue.record("未知 scenario：\(scenario)")
            }
        }
        // 至少比对过一次（vacuously passing 的 fixture 比没有 fixture 更危险）。
        #expect(counter.total > 0, "\(name) 没有产生任何比对")

    }

    // MARK: cron-message · 视图与 framing

    @Test("cron-message", arguments: S9FixtureLoader.names(kind: "cron-message"))
    @ContextTreeActor
    func cronMessage(_ name: String) async throws {
        let fixture = try #require(S9FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = CronAssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let label = caseItem["label"]?.stringValue ?? ""
            let input = caseItem["input"]?.objectValue ?? [:]
            switch scenario {
            case "view":
                var actual: [String: JSONValue] = [:]
                for (key, spec) in input["views"]?.objectValue ?? [:] {
                    let task = cronFixtureTask(spec.objectValue ?? [:])
                    actual[key] = .object(
                        buildCronTaskView(task, now: fixture.now, startedAt: fixture.startedAt, zone: fixture.zone).json
                    )
                }
                cronExpectSame(actual, caseItem["expect"]?.objectValue ?? [:], label)
            case "framing":
                let framing = renderCronTaskMessage(
                    id: input["id"]?.stringValue ?? "",
                    prompt: input["prompt"]?.stringValue ?? "",
                    slot: cronFixtureInstant(input["slot"]),
                    firedAt: cronFixtureInstant(input["firedAt"])
                )
                cronExpectSame(
                    ["framing": .string(framing)],
                    caseItem["expect"]?.objectValue ?? [:],
                    label,
                    counter: counter
                )
            default:
                Issue.record("未知 scenario：\(scenario)")
            }
        }
        // 至少比对过一次（vacuously passing 的 fixture 比没有 fixture 更危险）。
        #expect(counter.total > 0, "\(name) 没有产生任何比对")

    }

    // MARK: cron-runtime · 投递与手动触发

    @Test("cron-runtime", arguments: S9FixtureLoader.names(kind: "cron-runtime"))
    @ContextTreeActor
    func cronRuntime(_ name: String) async throws {
        let fixture = try #require(S9FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = CronAssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let label = caseItem["label"]?.stringValue ?? ""
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let input = caseItem["input"]?.objectValue ?? [:]
            let now = fixture.now

            switch scenario {
            case "delivery":
                var actual: [String: JSONValue] = [:]
                let warnings = WarningBox()
                let attempts = AttemptBox()
                let scenarios = input["scenarios"]?.arrayValue ?? []

                // 场景 1：先拒不后接受；at 消费后不再触发。
                let refuseStorage = MemoryCronStorage()
                let refusing = CronService(
                    storage: refuseStorage, timeZone: fixture.zone, clock: { now }, onWarning: { warnings.append($0) }
                )
                for spec in scenarios[0]["tasks"]?.arrayValue ?? [] {
                    _ = try refusing.addDynamicTask(spec.objectValue ?? [:])
                }
                let accept = AcceptBox()
                let refusingRuntime = CronRuntime(
                    service: refusing,
                    deliver: { _, _, task in
                        attempts.append(task.id)
                        return accept.value
                    },
                    options: CronRuntimeOptions(
                        clock: { now },
                        driver: SilentTimerDriver(),
                        tickSeconds: 3600,
                        firstTickDelay: .seconds(86_400),
                        onWarning: { warnings.append($0) }
                    )
                )
                await refusingRuntime.tick()
                actual["afterRefuse"] = .object(cronFixtureTaskState(
                    service: refusing, watch: "refused", warnings: warnings, attempts: attempts
                ))
                accept.value = true
                await refusingRuntime.tick()
                actual["afterAccept"] = .object(cronFixtureTaskState(
                    service: refusing, watch: "refused", warnings: warnings, attempts: attempts
                ))
                await refusingRuntime.tick()
                actual["afterConsumed"] = .object([
                    "historyCount": .int(Int64(refusing.listHistory().count)),
                    "deliverAttempts": .int(Int64(attempts.all.count)),
                    "warned": .int(Int64(warnings.all.count)),
                ])
                refusingRuntime.dispose()

                // 场景 2：交付端口抛错。
                let throwStorage = MemoryCronStorage()
                let throwing = CronService(
                    storage: throwStorage, timeZone: fixture.zone, clock: { now }, onWarning: { warnings.append($0) }
                )
                for spec in scenarios[1]["tasks"]?.arrayValue ?? [] {
                    _ = try throwing.addDynamicTask(spec.objectValue ?? [:])
                }
                let throwRuntime = CronRuntime(
                    service: throwing,
                    deliver: { _, _, _ in throw CronTestError.deliverFailed },
                    options: CronRuntimeOptions(
                        clock: { now },
                        driver: SilentTimerDriver(),
                        tickSeconds: 3600,
                        firstTickDelay: .seconds(86_400),
                        onWarning: { warnings.append($0) }
                    )
                )
                await throwRuntime.tick()
                actual["afterThrow"] = .object(cronFixtureTaskState(
                    service: throwing, watch: "boom", warnings: warnings, attempts: attempts
                ).without("deliverAttempts"))
                throwRuntime.dispose()

                // 场景 3：单任务故障隔离（一个抛错不阻断其他）。
                let isolatedStorage = MemoryCronStorage()
                let isolating = CronService(
                    storage: isolatedStorage, timeZone: fixture.zone, clock: { now }, onWarning: { warnings.append($0) }
                )
                for spec in scenarios[2]["tasks"]?.arrayValue ?? [] {
                    _ = try isolating.addDynamicTask(spec.objectValue ?? [:])
                }
                let isolateRuntime = CronRuntime(
                    service: isolating,
                    deliver: { _, _, task in
                        if task.id == "bad" { throw CronTestError.deliverFailed }
                        return true
                    },
                    options: CronRuntimeOptions(
                        clock: { now },
                        driver: SilentTimerDriver(),
                        tickSeconds: 3600,
                        firstTickDelay: .seconds(86_400),
                        onWarning: { warnings.append($0) }
                    )
                )
                await isolateRuntime.tick()
                actual["isolated"] = .object([
                    "goodDelivered": .int(Int64(isolating.listHistory().count)),
                    "warned": .int(Int64(warnings.all.count)),
                ])
                isolateRuntime.dispose()

                cronExpectSame(actual, expect, label, counter: counter)

            case "run-now":
                // 任务不存在 → not-found。
                let empty = CronService(
                    storage: MemoryCronStorage(), timeZone: fixture.zone, clock: { now }
                )
                let emptyRuntime = CronRuntime(
                    service: empty,
                    deliver: { _, _, _ in true },
                    options: CronRuntimeOptions(
                        clock: { now },
                        driver: SilentTimerDriver(),
                        tickSeconds: 3600,
                        firstTickDelay: .seconds(86_400)
                    )
                )
                let missing = await cronFixtureCode {
                    _ = try await emptyRuntime.runTaskNow(input["missingId"]?.stringValue ?? "ghost")
                }
                emptyRuntime.dispose()

                // 投递不可用 → delivery-unavailable。
                let busyStorage = MemoryCronStorage()
                let busy = CronService(
                    storage: busyStorage, timeZone: fixture.zone, clock: { now }
                )
                let taskId = input["unavailableTask"]?["id"]?.stringValue ?? "busy"
                _ = try busy.addDynamicTask(input["unavailableTask"]?.objectValue ?? [:])
                let busyRuntime = CronRuntime(
                    service: busy,
                    deliver: { _, _, _ in false },
                    options: CronRuntimeOptions(
                        clock: { now },
                        driver: SilentTimerDriver(),
                        tickSeconds: 3600,
                        firstTickDelay: .seconds(86_400)
                    )
                )
                let unavailable = await cronFixtureCode {
                    _ = try await busyRuntime.runTaskNow(taskId)
                }
                busyRuntime.dispose()

                cronExpectSame(
                    ["missing": missing, "unavailable": unavailable],
                    expect,
                    label,
                    counter: counter
                )

            default:
                Issue.record("未知 scenario：\(scenario)")
            }
        }
        // 至少比对过一次（vacuously passing 的 fixture 比没有 fixture 更危险）。
        #expect(counter.total > 0, "\(name) 没有产生任何比对")

    }

    // MARK: cron-tools · 工具结果文本

    @Test("cron-tools", arguments: S9FixtureLoader.names(kind: "cron-tools"))
    @ContextTreeActor
    func cronTools(_ name: String) async throws {
        let fixture = try #require(S9FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = CronAssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let label = caseItem["label"]?.stringValue ?? ""
            let input = caseItem["input"]?.objectValue ?? [:]
            let now = fixture.now
            let service = CronService(
                storage: MemoryCronStorage(), timeZone: fixture.zone, clock: { now }
            )
            _ = try service.addDynamicTask(input["task"]?.objectValue ?? [:])
            let ref = service.allocateRecordRef(now)
            let committed = service.commitFire(
                ref: ref,
                taskId: input["task"]?["id"]?.stringValue ?? "",
                slot: cronFixtureInstant(input["fire"]?["slot"]),
                firedAt: cronFixtureInstant(input["fire"]?["firedAt"])
            )
            _ = service.finishRun(
                committed.id,
                ok: { if case .bool(let flag) = input["finish"]?["ok"] { return flag }; return true }(),
                excerpt: input["finish"]?["excerpt"]?.stringValue
            )

            // 走真实工具层：ToolContext → ToolResult 的文本投影。
            let text: String
            switch scenario {
            case "list":
                let result = try await CronListTool(service: service).call(
                    ToolContext(ToolCall(name: "cron_list", callId: "s9", arguments: [:]))
                )
                text = result.content
            case "history":
                let result = try await CronHistoryTool(service: service).call(
                    ToolContext(ToolCall(
                        name: "cron_history",
                        callId: "s9",
                        arguments: ["limit": .int(Int64(input["historyLimit"]?.intValue ?? 20))]
                    ))
                )
                text = result.content
            default:
                Issue.record("未知 scenario：\(scenario)")
                continue
            }
            cronExpectSame(
                ["json": .string(text)],
                caseItem["expect"]?.objectValue ?? [:],
                label,
                counter: counter
            )
        }
        // 至少比对过一次（vacuously passing 的 fixture 比没有 fixture 更危险）。
        #expect(counter.total > 0, "\(name) 没有产生任何比对")

    }
}

// MARK: - 辅助

/// 按 fixture 的 expect 键裁剪投影（expect 是契约，不是各自的键清单）。
private func cronProjectKeys(
    _ full: [String: JSONValue],
    _ expect: [String: JSONValue]
) -> [String: JSONValue] {
    var projected: [String: JSONValue] = [:]
    for key in expect.keys.sorted() {
        projected[key] = full[key] ?? .null
    }
    return projected
}

/// 表达式允许值集合的投影（与导出器 `_fieldsOf` 同形）。
private func cronFixtureFields(_ parsed: CronExpression?) -> JSONValue {
    guard let parsed else { return .null }
    func sorted(_ values: Set<Int>) -> JSONValue {
        .array(values.sorted().map { .int(Int64($0)) })
    }
    return .object([
        "minute": sorted(parsed.minute),
        "hour": sorted(parsed.hour),
        "dom": sorted(parsed.dom),
        "month": sorted(parsed.month),
        "dow": sorted(parsed.dow),
    ])
}

/// 无时区信息的串按 fixture 声明的时区解释为本地墙钟。
///
/// fixture 的 `local` 字段刻意**不带偏移**（与来源的 `DateTime.parse` 同形），故不能
/// 走 `CronInstant.parse` 那条「无偏移按 UTC」的路径——先把墙钟字段拆出来在声明时区
/// 里组装，只有带偏移的串才交给 `CronInstant.parse`。
private func cronFixtureLocal(_ text: String, zone: TimeZone) -> Date {
    // 带偏移的判据：结尾 Z，或日期之后出现 ±HH:MM（日期本身的 `-` 不算）。
    let datePart = text.prefix(while: { $0.isNumber || $0 == "-" })
    let hasZone = text.hasSuffix("Z")
        || text.dropFirst(datePart.count).contains("+")
        || text.dropFirst(datePart.count).contains("-")
    if hasZone, let date = CronInstant.parse(text) { return date }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let parts = text.split(whereSeparator: { $0 == "-" || $0 == "T" || $0 == ":" })
    guard parts.count >= 5,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
          let hour = Int(parts[3]), let minute = Int(parts[4]) else {
        return CronInstant.parse(text) ?? Date(timeIntervalSince1970: 0)
    }
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = 0
    components.timeZone = zone
    return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
}

/// 运行时场景的任务状态投影（lastRunAt / firedAt / 历史数 / 交付次数 / 告警数）。
@ContextTreeActor
private func cronFixtureTaskState(
    service: CronService,
    watch: String,
    warnings: WarningBox,
    attempts: AttemptBox
) -> [String: JSONValue] {
    [
        "lastRunAt": CronInstant.format(service.findTask(watch)?.lastRunAt),
        "firedAt": CronInstant.format(service.findTask(watch)?.firedAt),
        "historyCount": .int(Int64(service.listHistory().count)),
        "deliverAttempts": .int(Int64(attempts.all.count)),
        "warned": .int(Int64(warnings.all.count)),
    ]
}

extension Dictionary where Key == String, Value == JSONValue {
    /// 去掉若干键（运行时的三个子场景投影键集不同）。
    fileprivate func without(_ keys: String...) -> [String: JSONValue] {
        var copy = self
        for key in keys { copy.removeValue(forKey: key) }
        return copy
    }
}

/// 测试用告警收集盒（投递端口与运行时同隔离域，闭包需可并发调用）。
final class WarningBox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }
    func append(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append(message)
    }
}

/// 交付尝试计数盒。
final class AttemptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return ids
    }
    func append(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        ids.append(id)
    }
}

/// 手动接受的投递开关。
final class AcceptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); defer { lock.unlock() }; flag = newValue }
    }
}

/// 测试用永不自己触发的定时器驱动（运行时只用手动 tick）。
struct SilentTimerDriver: TimerDriver {
    func wait(_ interval: Duration) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
    func now() -> Duration { .zero }
}

enum CronTestError: Error {
    case deliverFailed
}

/// 装载自检：每个 kind 必须恰好命中一个 fixture 文件、且用例非空。
///
/// 参数化用例在装载到空集合时会**静默跳过**，看起来像通过（本项目已吃过两次）。
@Suite("S9 fixtures 装载自检")
struct S9FixtureInventoryTests {
    @Test("s9 各 kind 恰好一件且用例非空", arguments: S9FixtureLoader.kinds)
    func inventory(_ kind: String) {
        let fixtures = S9FixtureLoader.load(kind: kind)
        #expect(fixtures.count == 1, "\(kind) 应恰好命中一个 fixture 文件（实际 \(fixtures.count)）")
        #expect(fixtures.first?.cases.isEmpty == false, "\(kind) 的用例不应为空")
    }

    @Test("s9 每条用例自带输入", arguments: S9FixtureLoader.kinds)
    func selfDescribing(_ kind: String) {
        for fixture in S9FixtureLoader.load(kind: kind) {
            for caseItem in fixture.cases {
                let scenario = caseItem["scenario"]?.stringValue ?? "?"
                #expect(
                    caseItem["input"] != nil,
                    "\(fixture.name)/\(scenario) 缺 input：输入必须写进 fixture，否则运行器只能手抄一份输入矩阵"
                )
            }
        }
    }

    @Test("s9 规则域固定为 UTC 语义", arguments: S9FixtureLoader.kinds)
    func zone(_ kind: String) {
        for fixture in S9FixtureLoader.load(kind: kind) {
            let declared = fixture.raw["localZone"]?.stringValue
            #expect(declared == "UTC", "\(fixture.name) 的 localZone 应为 UTC（实际 \(declared ?? "缺")）")
            // TimeZone(identifier: "UTC") 在 macOS 上的 identifier 是 GMT，断言偏移而不是名字。
            #expect(fixture.zone.secondsFromGMT() == 0, "\(fixture.name) 的时区偏移应为 0")
        }
    }
}
