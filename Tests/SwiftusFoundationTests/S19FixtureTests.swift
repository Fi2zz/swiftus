import Foundation
import SwiftusCore
import SwiftusFoundation
import Testing

/// 规格 S19 golden fixtures：database / timer / time-context / logger / loader。
@Suite("S19 golden fixtures")
struct S19FixtureTests {
    // MARK: database · hub

    @Test("database-hub", arguments: S18FixtureLoader.load(kind: "database-hub", spec: "s19"))
    @ContextTreeActor
    func databaseHub(_ fixture: S18Fixture) async throws {
        let dir = s19TempDir()
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = try await runHubCase(caseItem["scenario"]?.stringValue ?? "", dir: dir)
            s18ExpectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    @ContextTreeActor
    private func runHubCase(_ scenario: String, dir: URL) async throws -> [String: JSONValue] {
        switch scenario {
        case "register":
            let hub = Database()
            try hub.register("json", JsonDatabaseBackend(dir: dir.appending(path: "a").path))
            try hub.register("memory", StubBackend())
            let duplicate = await s19Attempt {
                try hub.register("json", StubBackend())
                return .string("registered")
            }
            let emptyName = await s19Attempt {
                try hub.register("", StubBackend())
                return .string("registered")
            }
            return [
                "backendNames": .array(hub.backendNames.map { .string($0) }),
                "duplicate": duplicate,
                "emptyName": emptyName,
                "namesAfterRejects": .array(hub.backendNames.map { .string($0) }),
            ]
        case "route":
            let routes = Database(defaultBackend: "json")
            try routes.register("json", JsonDatabaseBackend(dir: dir.appending(path: "b").path))
            try routes.register("other", StubBackend())
            let explicit = try await routes.open("u1", backend: "other")
            let byDefault = try await routes.open("u2")
            let unknown = await s19Attempt {
                _ = try await routes.open("u3", backend: "nope")
                return .string("opened")
            }
            let ambiguous = Database()
            try ambiguous.register("x", StubBackend())
            try ambiguous.register("y", StubBackend())
            let noBackend = await s19Attempt {
                _ = try await ambiguous.open("u")
                return .string("opened")
            }
            let single = Database()
            try single.register("only", StubBackend())
            let bySole = try await single.open("u")
            return [
                "explicitBackendUnit": .string(explicit.name),
                "defaultBackendUnit": .string(byDefault.name),
                "unknownBackend": unknown,
                "ambiguous": noBackend,
                "soleRegisteredUnit": .string(bySole.name),
            ]
        case "open":
            let hub = Database(defaultBackend: "json")
            try hub.register("json", JsonDatabaseBackend(dir: dir.appending(path: "c").path))
            let first = try await hub.open("profile")
            try await first.put("name", .string("助手"))
            let second = try await hub.open("scratch")
            let alreadyOpen = await s19Attempt {
                _ = try await hub.open("profile")
                return .string("opened")
            }
            let emptyUnit = await s19Attempt {
                _ = try await hub.open("")
                return .string("opened")
            }
            let unitsOpened = hub.unitNames
            let found = hub.get("profile")?.name
            let missing = hub.get("ghost")?.name
            let closedOne = hub.close("profile")
            let closedGhost = hub.close("ghost")
            let unitClosedAfterHubClose = first.closed
            hub.closeAll()
            return [
                "unitsBeforeClose": .array(unitsOpened.map { .string($0) }),
                "alreadyOpen": alreadyOpen,
                "emptyUnit": emptyUnit,
                "getFound": found.map { .string($0) } ?? .null,
                "getMissing": missing.map { .string($0) } ?? .null,
                "closeOne": .bool(closedOne),
                "closeGhost": .bool(closedGhost),
                "unitClosedAfterHubClose": .bool(unitClosedAfterHubClose),
                "unitClosedAfterCloseAll": .bool(second.closed),
                "lengthAfterCloseAll": .int(Int64(hub.count)),
                "unitsAfterCloseAll": .array(hub.unitNames.map { .string($0) }),
            ]
        case "disposer":
            let hub = Database()
            let off = try hub.register("b", StubBackend())
            try? off()
            try hub.register("b", StubBackend())
            try? off() // 过期撤销：不得移除新后端
            let stillThere = await s19Attempt {
                _ = try hub.backend("b")
                return .string("present")
            }
            return [
                "namesAfterSwap": .array(hub.backendNames.map { .string($0) }),
                "stillResolvable": stillThere,
            ]
        default:
            Issue.record("未知 scenario：\(scenario)")
            return [:]
        }
    }

    // MARK: database · 单元

    @Test("database-unit", arguments: S18FixtureLoader.load(kind: "database-unit", spec: "s19"))
    @ContextTreeActor
    func databaseUnit(_ fixture: S18Fixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = try await runUnitCase(caseItem["scenario"]?.stringValue ?? "", input: caseItem["input"] ?? .object([:]))
            s18ExpectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    @ContextTreeActor
    private func runUnitCase(_ scenario: String, input: JSONValue) async throws -> [String: JSONValue] {
        let hub = Database(defaultBackend: "stub")
        try hub.register("stub", StubBackend())
        let unit = try await hub.open(input["unit"]?.stringValue ?? "u")
        var changes: [JSONValue] = []
        let token = unit.onChange { change in
            changes.append(.object([
                "unit": .string(change.unit),
                "key": .string(change.key),
                "kind": .string(change.kind.rawValue),
                // 「值是空的」在 Dart 是 null、在 Swift 是 .null → 投影成同一个布尔。
                "valueIsNull": .bool(change.value == nil || change.value == .null),
            ]))
        }
        for put in input["puts"]?.arrayValue ?? [] {
            try await unit.put(put["key"]?.stringValue ?? "k", put["value"] ?? .null)
        }
        var deletedValues: [Bool] = []
        for key in input["deletes"]?.arrayValue ?? [] {
            deletedValues.append(try await unit.delete(key.stringValue ?? ""))
        }
        let changesAfterWrites = changes

        switch scenario {
        case "write-chain":
            return [
                "changes": .array(changesAfterWrites),
                "deleteExisting": .bool(deletedValues.first ?? false),
                "deleteMissing": .bool(deletedValues.count > 1 ? deletedValues[1] : false),
                "entries": .object(unit.entries),
                "keys": .array(unit.keys.sorted().map { .string($0) }),
                "length": .int(Int64(unit.length)),
                "hasEmptyValue": .bool(unit.has("empty")),
                "getMissingIsNull": .bool(unit.get("ghost") == nil),
            ]
        default:
            unit.close()
            let afterClose = await s19Attempt {
                try await unit.put("x", .int(1))
                return .string("written")
            }
            unit.close()
            unit.removeChangeListener(token)
            _ = await s19Attempt {
                try await unit.put("y", .int(2))
                return .string("written")
            }
            return [
                "afterClose": afterClose,
                "closed": .bool(unit.closed),
                "changesAfterClose": .int(Int64(changesAfterWrites.count)),
                "hubUnits": .array(hub.unitNames.map { .string($0) }),
            ]
        }
    }

    // MARK: database · JSON 后端

    @Test("database-json", arguments: S18FixtureLoader.load(kind: "database-json", spec: "s19"))
    @ContextTreeActor
    func databaseJson(_ fixture: S18Fixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let input = caseItem["input"]?.objectValue ?? [:]
            let dir = s19TempDir().appending(path: "json-\(UUID().uuidString)")
            let backend = JsonDatabaseBackend(dir: dir.path)
            var actual: [String: JSONValue]
            switch caseItem["scenario"]?.stringValue {
            case "roundtrip":
                let unit = input["unit"]?.stringValue ?? "u1"
                let records = input["records"] ?? .object([:])
                let missing = try await backend.load("missing")
                try await backend.save(unit, records.objectValue ?? [:])
                let reloaded = try await backend.load(unit)
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                    .filter { !$0.contains(".tmp-") }
                    .sorted() ?? []
                try await backend.deleteUnit(unit)
                let afterDelete = try await backend.load(unit)
                await backend.close()
                actual = [
                    "loadMissing": .object(missing),
                    "reloaded": .object(reloaded),
                    "files": .array(files.map { .string($0) }),
                    "loadAfterDelete": .object(afterDelete),
                ]
            default:
                let file = input["file"]?.stringValue ?? "array.json"
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try (input["content"]?.stringValue ?? "[]").write(
                    to: dir.appending(path: file),
                    atomically: true,
                    encoding: .utf8
                )
                let malformed = await s19Attempt {
                    _ = try await backend.load("array")
                    return .string("loaded")
                }
                let slashUnit = await s19Attempt {
                    _ = try await backend.load("a/b")
                    return .string("loaded")
                }
                let emptyUnit = await s19Attempt {
                    _ = try await backend.load("")
                    return .string("loaded")
                }
                actual = ["malformed": malformed, "slashUnit": slashUnit, "emptyUnit": emptyUnit]
            }
            s18ExpectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    // MARK: timer

    @Test("timer", arguments: S18FixtureLoader.load(kind: "timer", spec: "s19"))
    @ContextTreeActor
    func timer(_ fixture: S18Fixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = try await runTimerCase(caseItem["scenario"]?.stringValue ?? "")
            s18ExpectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    @ContextTreeActor
    private func runTimerCase(_ scenario: String) async throws -> [String: JSONValue] {
        switch scenario {
        case "timeout":
            // 「等多久」一律有界轮询，不用固定 sleep：300+ 用例并发 + release 优化下
            // 固定 200ms 会踩空（本项目在 release 全量跑时红过一次，firedOnce 落 0）。
            let ctx = Context.root(name: "timer/timeout")
            let fired = Counter()
            let off: Disposer = ctx.timeout({ fired.bump() }, after: .milliseconds(40))
            try await s19Eventually("timeout 触发") { fired.value >= 1 }
            try? off()
            let afterTimeout = fired.value
            let ctx2 = Context.root(name: "timer/timeout-cancel")
            let cancelled = Counter()
            let off2: Disposer = ctx2.timeout({ cancelled.bump() }, after: .milliseconds(40))
            try? off2()
            try await Task.sleep(for: .milliseconds(200))
            return [
                "firedOnce": .int(Int64(afterTimeout)),
                "firedAfterExplicitDisposer": .int(Int64(cancelled.value)),
            ]
        case "interval":
            let ctx = Context.root(name: "timer/interval")
            let ticks = Counter()
            let off: Disposer = ctx.interval({ ticks.bump() }, every: .milliseconds(40))
            try await s19Eventually("interval 触发多次") { ticks.value >= 2 }
            ctx.dispose()
            let atDispose = ticks.value
            try await Task.sleep(for: .milliseconds(160))
            try? off()
            return [
                "tickedMultipleTimes": .bool(atDispose >= 2),
                "stoppedAfterDispose": .bool(ticks.value == atDispose),
            ]
        case "sleep":
            let ctx = Context.root(name: "timer/sleep")
            var slept = false
            do {
                try await ctx.sleep(.milliseconds(40))
                slept = true
            } catch {
                // 到点前被中断即视为未睡成（只断言 sleep 是否正常完成）。
            }
            let ctx2 = Context.root(name: "timer/sleep-cut")
            var interrupted = false
            // 释放方任务继承 actor 隔离（Task {} 在 actor 方法内创建），故可安全 dispose。
            let releaser = Task {
                try await Task.sleep(for: .milliseconds(40))
                ctx2.dispose()
            }
            do {
                try await ctx2.sleep(.seconds(30))
            } catch {
                // 错误**类型**随语言而异（StateError / ContextDisposedError）：
                // fixture 只断言「以错误结束而不是悬挂」，类型由单元测试锁定。
                interrupted = true
            }
            releaser.cancel()
            return [
                "slept": .bool(slept),
                "interrupted": .bool(interrupted),
            ]
        case "throttle-debounce":
            let ctx = Context.root(name: "timer/throttle")
            var throttled = 0
            let th = ctx.throttle({ throttled += 1 }, .milliseconds(80))
            th.call()
            th.call()
            th.call()
            let immediate = throttled
            try await Task.sleep(for: .milliseconds(260))
            let afterWindow = throttled
            th.call()
            let afterSecondCall = throttled
            th.dispose()
            th.call()

            let ctx2 = Context.root(name: "timer/debounce")
            var debounced = 0
            let db = ctx2.debounce({ debounced += 1 }, .milliseconds(80))
            db.call()
            db.call()
            db.call()
            let beforeWindow = debounced
            try await Task.sleep(for: .milliseconds(260))
            let afterDebounce = debounced
            db.dispose()
            db.call()
            try await Task.sleep(for: .milliseconds(160))
            return [
                "throttledImmediate": .int(Int64(immediate)),
                "throttledAfterWindow": .int(Int64(afterWindow)),
                "throttledSecondCallRuns": .bool(afterSecondCall == afterWindow + 1),
                "debouncedBeforeWindow": .int(Int64(beforeWindow)),
                "debouncedAfterWindow": .int(Int64(afterDebounce)),
                "debouncedOnce": .bool(afterDebounce == 1),
            ]
        default:
            Issue.record("未知 scenario：\(scenario)")
            return [:]
        }
    }

    // MARK: time-context

    @Test("time-context", arguments: S18FixtureLoader.load(kind: "time-context", spec: "s19"))
    @ContextTreeActor
    func timeContext(_ fixture: S18Fixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let input = caseItem["input"]?.objectValue ?? [:]
            let actual: [String: JSONValue]
            if let instant = input["instant"]?.stringValue {
                guard let date = try? Date(instant, strategy: .iso8601) else {
                    Issue.record("用例的 instant 不可解析：\(instant)")
                    continue
                }
                let secondsFromGMT = Int(input["offsetSeconds"]?.intValue ?? 0)
                let zoneName = input["zoneName"]?.stringValue
                let ctx = Context.root()
                let prompt = try provideSystemPrompt(ctx)
                let off: Disposer = try provideTimePrompt(ctx, prompt: prompt) { _ in
                    ZonedInstant(
                        date: date,
                        zoneName: zoneName ?? "UTC",
                        secondsFromGMT: secondsFromGMT
                    )
                }
                let assembly = prompt.assemble()
                try? off()
                ctx.dispose()
                guard let section = assembly.contexts.first(where: { $0.name == kTimeContextName }) else {
                    Issue.record("未注册 time 上下文")
                    continue
                }
                actual = [
                    "name": .string(section.name),
                    "isFirstContext": .bool(assembly.contexts.first?.name == kTimeContextName),
                    "text": .string(section.text),
                ]
            } else {
                // 偏移格式化（无渲染上下文）。
                var formatted: [String: JSONValue] = [:]
                for (index, key) in ["plus8", "minusHalf", "utc", "plusHalf"].enumerated() {
                    let seconds = [28800, -19800, 0, 1800][index]
                    formatted[key] = .string(formatClockOffset(secondsFromGMT: seconds))
                }
                actual = formatted
            }
            s18ExpectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    // MARK: logger

    @Test("logger", arguments: S18FixtureLoader.load(kind: "logger", spec: "s19"))
    @ContextTreeActor
    func logger(_ fixture: S18Fixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = runLoggerCase(caseItem["scenario"]?.stringValue ?? "")
            s18ExpectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    @ContextTreeActor
    private func runLoggerCase(_ scenario: String) -> [String: JSONValue] {
        switch scenario {
        case "level-ring":
            let service = LoggerService(defaultName: "root", level: .warn, recentLimit: 3)
            let collector = LogCollector()
            service.addExporter(collector)
            service.debug("d")
            service.info("i")
            service.warn("w")
            service.error("e")
            service.error("e2")
            service.error("e3")
            let beforeRemove = collector.records.count
            let removed = service.removeExporter(collector)
            let removedAgain = service.removeExporter(collector)
            service.error("after")
            return [
                "exportedBeforeRemove": .int(Int64(beforeRemove)),
                "exportedAfterRemove": .int(Int64(collector.records.count)),
                "removed": .bool(removed),
                "removedAgain": .bool(removedAgain),
                "recentMessages": .array(service.recent.map { .string($0.message) }),
                "recentCount": .int(Int64(service.recent.count)),
                "exporters": .int(Int64(service.exporters.count)),
            ]
        case "named":
            let service = LoggerService()
            let collector = LogCollector()
            service.addExporter(collector)
            service.logger("chat").info("会话超时", "timeout", "frame-1\nframe-2")
            service.error("根级")
            return [
                "records": .array(collector.records.map { record in
                    .object([
                        "level": .string(String(describing: record.level)),
                        "name": .string(record.name),
                        "message": .string(record.message),
                        "hasError": .bool(record.error != nil),
                        "hasStackTrace": .bool(record.stackTrace != nil),
                        "hasTime": .bool(record.time != Date(timeIntervalSince1970: 0)),
                    ])
                }),
            ]
        default:
            let box = LineBox()
            let sink: LogWriter = { box.append($0) }
            let service = LoggerService(level: .debug)
            service.addExporter(ConsoleExporter(writer: sink))
            service.debug("d")
            service.warn("w", "boom")
            service.error("e", "bad", "trace")
            let filteredService = LoggerService(level: .debug)
            filteredService.addExporter(ConsoleExporter(writer: sink, level: .error))
            filteredService.info("below")
            let timedService = LoggerService(level: .debug)
            timedService.addExporter(ConsoleExporter(writer: sink, showTime: true))
            timedService.info("has-time")
            // showTime 的 ISO 时刻是墙钟 → 归一为 <time> 后只比对形状（与导出器同款）。
            let normalized = box.lines.map { line in
                line.replacingOccurrences(
                    of: #"^\d{4}-\d{2}-\d{2}T[^ ]* "#,
                    with: "<time> ",
                    options: .regularExpression
                )
            }
            let last = normalized.last ?? ""
            let isoPrefix = last.range(
                of: #"^<time> \[I\] root  has-time$"#,
                options: .regularExpression
            ) != nil
            return [
                "lines": .array(normalized.map { .string($0) }),
                "showTimeAddsIsoPrefix": .bool(isoPrefix),
            ]
        }
    }

    // MARK: loader

    @Test("loader", arguments: S18FixtureLoader.load(kind: "loader", spec: "s19"))
    @ContextTreeActor
    func loader(_ fixture: S18Fixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = try await runLoaderCase(caseItem["scenario"]?.stringValue ?? "")
            s18ExpectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    @ContextTreeActor
    private func runLoaderCase(_ scenario: String) async throws -> [String: JSONValue] {
        switch scenario {
        case "register":
            let ctx = Context.root()
            let loader = try provideLoader(ctx, plugins: [
                "a": { _, config in _ = config },
                "b": { _, config in _ = config },
            ])
            let emptyName = await s19Attempt {
                try loader.register("", { _, _ in })
                return .string("registered")
            }
            try loader.register("a") { _, config in _ = config }
            let unregistered = loader.unregister("b")
            let unregisteredAgain = loader.unregister("b")
            return [
                "emptyName": emptyName,
                "names": .array(loader.names.map { .string($0) }),
                "hasA": .bool(loader.has("a")),
                "hasB": .bool(loader.has("b")),
                "unregistered": .bool(unregistered),
                "unregisteredAgain": .bool(unregisteredAgain),
            ]
        case "load":
            var log: [String] = []
            let ctx = Context.root()
            let loader = try provideLoader(ctx, plugins: [
                "a": { child, config in
                    // 记号与导出器同款（on:/off:），日志才可比。
                    log.append("on:\(config?.stringValue ?? "-")")
                    child.track { log.append("off:\(config?.stringValue ?? "-")") }
                },
            ])
            let id1 = try loader.load(LoaderEntry(name: "a", config: .string("x")))
            let id2 = try loader.load(LoaderEntry(name: "a", config: .string("y")))
            let groupId = try loader.load(LoaderEntry(
                id: "g",
                children: [LoaderEntry(name: "a", config: .string("child"))]
            ))
            let childId = loader.ids.first { $0.hasPrefix("\(groupId):") } ?? ""
            let duplicateId = await s19Attempt {
                _ = try loader.load(LoaderEntry(id: id1, name: "a"))
                return .string("loaded")
            }
            let unknownPlugin = await s19Attempt {
                _ = try loader.load(LoaderEntry(id: "nope", name: "nope"))
                return .string("loaded")
            }
            let residue = loader.ids.contains("nope")
            let groupContext = loader.contextOf(groupId) != nil
            try loader.remove(id1)
            let logAfterRemove = log
            let idGone = !loader.ids.contains(id1)
            let logLengthBeforeReload = log.count
            try loader.reload(childId)
            let reloadSingle = log.count == logLengthBeforeReload + 1
            let reloadUnknown = await s19Attempt {
                try loader.reload("ghost")
                return .string("reloaded")
            }
            let removeUnknown = await s19Attempt {
                try loader.remove("ghost")
                return .string("removed")
            }
            let idShape = #"^entry-\d+$"#
            return [
                "firstIdShape": .bool(id1.range(of: idShape, options: .regularExpression) != nil),
                "secondIdShape": .bool(id2.range(of: idShape, options: .regularExpression) != nil),
                "distinctIds": .bool(id1 != id2),
                "groupId": .string(groupId),
                "childIdHasPrefix": .bool(childId.hasPrefix("\(groupId):")),
                "idsInLoadOrder": .array(loader.ids.map { .string($0) }),
                "isEmptyFalse": .bool(!loader.isEmpty),
                "duplicateId": duplicateId,
                "unknownPlugin": unknownPlugin,
                "unknownPluginResidue": .bool(residue),
                "groupHasNoContext": .bool(!groupContext),
                "entryOfGroupIsGroup": .bool(loader.entryOf(groupId)?.isGroup ?? false),
                "logAfterRemove": .array(logAfterRemove.map { .string($0) }),
                "idGoneAfterRemove": .bool(idGone),
                "reloadKeepsSingleContext": .bool(reloadSingle),
                "reloadUnknown": reloadUnknown,
                "removeUnknown": removeUnknown,
            ]
        case "apply":
            var log: [String] = []
            let ctx = Context.root()
            let loader = try provideLoader(ctx, plugins: [
                "a": { child, config in
                    log.append("on:\(config?.stringValue ?? "-")")
                    child.track { log.append("off:\(config?.stringValue ?? "-")") }
                },
            ])
            try loader.apply([
                LoaderEntry(id: "one", name: "a", config: .string("1")),
                LoaderEntry(id: "two", name: "a", config: .string("2")),
            ])
            try loader.apply([LoaderEntry(id: "only", name: "a", config: .string("3"))])
            return [
                "ids": .array(loader.ids.map { .string($0) }),
                "isEmptyFalse": .bool(!loader.isEmpty),
                "log": .array(log.map { .string($0) }),
            ]
        default:
            var log: [String] = []
            let ctx = Context.root()
            let loader = try provideLoader(ctx, plugins: [
                "a": { _, config in log.append("on:\(config?.stringValue ?? "-")") },
            ])
            try loader.applyJson([
                .object([
                    "id": .string("top"),
                    "children": .array([
                        .object(["name": .string("a"), "config": .string("nested")]),
                        .object(["name": .string("a"), "disabled": .bool(true)]),
                    ]),
                ]),
            ])
            let disabledId = loader.ids.count > 1 ? loader.ids[1] : ""
            let disabledHasContext = !disabledId.isEmpty && loader.contextOf(disabledId) != nil
            let roundtrip = try LoaderEntry.from(loader.entryOf("top")?.json ?? .object([:])).json
            return [
                "ids": .array(loader.ids.map { .string($0) }),
                "log": .array(log.map { .string($0) }),
                "disabledHasNoContext": .bool(!disabledHasContext),
                "groupRoundtrip": roundtrip,
            ]
        }
    }
}

// MARK: - 替身与工具

/// 内存后端替身：只记录最后一次 save 的整表。
@ContextTreeActor
final class StubBackend: DatabaseBackend {
    private(set) var saves = 0
    private(set) var closedFlag = false
    private var store: [String: [String: JSONValue]] = [:]

    func load(_ unit: String) async throws -> [String: JSONValue] {
        store[unit] ?? [:]
    }

    func save(_ unit: String, _ records: [String: JSONValue]) async throws {
        saves += 1
        store[unit] = records
    }

    func deleteUnit(_ unit: String) async throws {
        store.removeValue(forKey: unit)
    }

    func close() async {
        closedFlag = true
    }
}

/// 收集控制台导出行（`@Sendable` 闭包不能改捕获的 var，故用锁盒）。
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []

    func append(_ line: String) {
        lock.lock()
        buffer.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// 日志收集器（导出器替身）。
@ContextTreeActor
final class LogCollector: LogExporter {
    private(set) var records: [LogRecord] = []

    func export(_ record: LogRecord) {
        records.append(record)
    }
}

/// 本轮 fixtures 的临时根（每个用例一份，避免并发用例互相覆盖文件）。
@ContextTreeActor
func s19TempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "swiftus-s19-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return URL(fileURLWithPath: dir.path).resolvingSymlinksInPath()
}

/// 执行一步并把异常收敛成 `{error: 码}`。
@ContextTreeActor
func s19Attempt(_ body: () async throws -> JSONValue) async -> JSONValue {
    do {
        return try await body()
    } catch let error as DatabaseException {
        return .object(["error": .string(error.code.rawValue)])
    } catch let error as LoaderException {
        return .object(["error": .string(error.message)])
    } catch {
        return .object(["error": .string(String(describing: type(of: error)))])
    }
}
