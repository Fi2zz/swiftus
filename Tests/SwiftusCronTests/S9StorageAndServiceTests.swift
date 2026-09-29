import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusCron
import Testing

/// S9 单元测试：fixtures 够不到的缝——**真文件存储**、**上下文装配**、**定时器驱动**。
///
/// fixtures 锁的是「给定输入下的行为」，下面这些是「宿主能不能真的用起来」：
/// 任务能不能跨进程重启回来、工具能不能注册进注册表、tick 会不会按节奏响。
@Suite("S9 存储与装配")
struct S9StorageAndServiceTests {
    /// fixtures 用的临时根。
    static let root: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "swiftus-s9-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: dir.path).resolvingSymlinksInPath()
    }()

    @Test("任务与历史跨「重启」恢复：动态任务、运行戳、启停覆盖都落盘")
    @ContextTreeActor
    func restartPersistence() async throws {
        let storage = JsonCronStorage(
            tasksPath: Self.root.appending(path: "tasks.json").path,
            historyPath: Self.root.appending(path: "history.jsonl").path
        )
        let start = CronInstant.parse("2026-03-09T10:00:00Z")!
        let first = CronService(
            storage: storage,
            timeZone: TimeZone(identifier: "UTC")!,
            clock: { start }
        )
        _ = try first.addDynamicTask(["id": .string("keep"), "prompt": .string("留下"), "every": .int(600)])
        _ = try first.addDynamicTask(["id": .string("gone"), "prompt": .string("删掉"), "every": .int(600)])
        _ = try first.setEnabled("keep", false)
        let ref = first.allocateRecordRef(start)
        _ = first.commitFire(ref: ref, taskId: "keep", slot: start, firedAt: start)
        _ = first.finishRun(ref.id, ok: true, excerpt: "干完了")
        try first.removeDynamicTask("gone")

        // 换一个服务实例读同一份文件 = 模拟进程重启。
        let second = CronService(
            storage: storage,
            timeZone: TimeZone(identifier: "UTC")!,
            clock: { start }
        )
        #expect(second.tasks.map(\.id) == ["keep"])
        let restored = try #require(second.findTask("keep"))
        #expect(restored.prompt == "留下")
        #expect(restored.every == 600)
        #expect(restored.isEnabled == false, "启停覆盖应恢复")
        #expect(restored.lastRunAt == start, "运行戳应恢复")
        #expect(second.listHistory().count == 1)
        #expect(second.listHistory().first?.status == .completed)
        #expect(second.listHistory().first?.excerpt == "干完了")
    }

    @Test("内部缓存不进持久文件（显式字段表）")
    @ContextTreeActor
    func noInternalCacheInFile() async throws {
        let path = Self.root.appending(path: "cache-tasks.json").path
        let storage = JsonCronStorage(tasksPath: path, historyPath: Self.root.appending(path: "cache-history.jsonl").path)
        let now = CronInstant.parse("2026-03-09T10:00:00Z")!
        let service = CronService(storage: storage, timeZone: TimeZone(identifier: "UTC")!, clock: { now })
        _ = try service.addDynamicTask(["id": .string("c"), "prompt": .string("cron 任务"), "cron": .string("*/15 * * * *")])
        // 先算一次 nextRunAt 把 cronNext 缓存填上，再落盘。
        _ = service.taskView(try #require(service.findTask("c")))

        let text = try String(contentsOfFile: path, encoding: .utf8)
        let object = try #require(try JSONValue.parse(Data(text.utf8)).objectValue)
        let task = try #require(object["tasks"]?.arrayValue?.first?.objectValue)
        #expect(Set(task.keys) == ["id", "prompt", "cron", "sessionId", "enabled"])
        #expect(task["sessionId"] == .null)
        #expect(Int(object["version"]?.intValue ?? 0) == kCronStorageVersion)
    }

    @Test("读取宽容降级：缺文件与损坏文件都视为空，写入失败不抛")
    @ContextTreeActor
    func lenientReads() async throws {
        let missing = JsonCronStorage(
            tasksPath: Self.root.appending(path: "nope/tasks.json").path,
            historyPath: Self.root.appending(path: "nope/history.jsonl").path
        )
        #expect(missing.loadTasks() == .empty)
        #expect(missing.loadHistory().isEmpty)

        // 损坏的 JSON：告警 + 视为空。
        let brokenPath = Self.root.appending(path: "broken-tasks.json")
        try Data("{ 这不是 json".utf8).write(to: brokenPath)
        let warnings = WarningBox()
        let broken = JsonCronStorage(
            tasksPath: brokenPath.path,
            historyPath: Self.root.appending(path: "broken-history.jsonl").path,
            onWarning: { warnings.append($0) }
        )
        #expect(broken.loadTasks() == .empty)

        // 写入失败（父路径是文件而不是目录）：不抛，只告警。
        let blocked = JsonCronStorage(
            tasksPath: brokenPath.path + "/tasks.json",
            historyPath: brokenPath.path + "/history.jsonl",
            onWarning: { warnings.append($0) }
        )
        blocked.saveTasks(tasks: [], runStamps: [:], overrides: [:])
        #expect(warnings.all.count >= 1, "写入失败应走告警而不是抛出")
    }

    @Test("历史 JSONL 容忍错行与旧格式（毫秒数时刻）")
    @ContextTreeActor
    func lenientHistoryDecode() async throws {
        let historyPath = Self.root.appending(path: "mixed-history.jsonl")
        let lines = [
            #"{"id":"run-0-a","seq":0,"taskId":"t","prompt":"好","scheduledFor":1773000000000,"firedAt":1773000000000,"status":"delivered"}"#,
            "这行不是 json",
            #"{"seq":9}"#, // 缺 id → 跳过
        ].joined(separator: "\n")
        try Data((lines + "\n").utf8).write(to: historyPath)
        let storage = JsonCronStorage(
            tasksPath: Self.root.appending(path: "mixed-tasks.json").path,
            historyPath: historyPath.path
        )
        let records = storage.loadHistory().compactMap { CronRunRecord.decode($0) }
        #expect(records.count == 1, "错行与缺 id 的行应被跳过")
        #expect(records.first?.id == "run-0-a")
        #expect(records.first?.status == .delivered)
        #expect(records.first?.scheduledFor.timeIntervalSince1970 == 1_773_000_000)
    }

    @Test("服务作为 `cron` 提供到上下文，五个工具经管线注册")
    @ContextTreeActor
    func contextWiring() async throws {
        let ctx = Context.root()
        let registry = ToolRegistry()
        try ctx.provide(.tools, registry)
        let now = CronInstant.parse("2026-03-09T10:00:00Z")!
        let service = try provideCron(
            ctx,
            storage: MemoryCronStorage(),
            timeZone: TimeZone(identifier: "UTC")!,
            clock: { now }
        )
        #expect(ctx.get(.cron) === service)
        let tools = try provideCronTools(ctx, callerSessionId: "s-caller")
        #expect(tools.map(\.name) == ["cron_list", "cron_history", "cron_add", "cron_update", "cron_remove"])
        #expect(registry.names.sorted() == [
            "cron_add", "cron_history", "cron_list", "cron_remove", "cron_update",
        ])

        // 经注册表跑一次 cron_add：会话绑定按调用方会话落定。
        let call = ToolCall(
            name: "cron_add",
            callId: "c1",
            arguments: ["prompt": .string("每分钟看一眼"), "every": .int(60)]
        )
        let result = await registry.call(call)
        #expect(!result.failed, "cron_add 应成功：\(result.content)")
        let view = try #require(service.tasks.first)
        #expect(view.sessionId == "s-caller", "未显式传 session_id 时绑定调用方会话")
        #expect(view.every == 60)

        // 上下文释放 → 工具随效应撤销。
        ctx.dispose()
        #expect(registry.names.isEmpty, "工具注册应随上下文释放撤销")
    }

    @Test("配置任务：不可改不可删，但可以停用")
    @ContextTreeActor
    func configTaskProtection() async throws {
        let warnings = WarningBox()
        let now = CronInstant.parse("2026-03-09T10:00:00Z")!
        let service = CronService(
            storage: MemoryCronStorage(),
            configTasks: [["id": .string("cfg"), "prompt": .string("配置任务"), "daily": .string("08:00")]],
            timeZone: TimeZone(identifier: "UTC")!,
            clock: { now },
            onWarning: { warnings.append($0) }
        )
        #expect(warnings.all.isEmpty, "合法配置任务不该告警")
        #expect(service.findTask("cfg")?.origin == .config)

        do {
            _ = try service.updateDynamicTask("cfg", ["prompt": .string("改")])
            Issue.record("配置任务应拒绝编辑")
        } catch let error as CronException {
            #expect(error.code == .configTask)
            #expect(error.message.contains("edit it there"))
        }
        do {
            try service.removeDynamicTask("cfg")
            Issue.record("配置任务应拒绝删除")
        } catch let error as CronException {
            #expect(error.code == .configTask)
        }
        // 停用走 requireTask，配置任务也允许。
        let view = try service.setEnabled("cfg", false)
        #expect(view.enabled == false)
    }

    @Test("id 冲突与非法输入的错误码与消息")
    @ContextTreeActor
    func errorCodes() async throws {
        let service = CronService(storage: MemoryCronStorage())
        _ = try service.addDynamicTask(["id": .string("a"), "prompt": .string("p"), "every": .int(60)])
        do {
            _ = try service.addDynamicTask(["id": .string("a"), "prompt": .string("p"), "every": .int(60)])
            Issue.record("重 id 应被拒")
        } catch let error as CronException {
            #expect(error.code == .duplicateId)
            #expect(error.message == "task \"a\" already exists")
        }
        do {
            _ = try service.addDynamicTask(["id": .string("b"), "prompt": .string("p"), "every": .int(5)])
            Issue.record("间隔过小应被拒")
        } catch let error as CronException {
            #expect(error.code == .invalidTask)
        }
        do {
            try service.removeDynamicTask("ghost")
            Issue.record("删除不存在的任务应报错")
        } catch let error as CronException {
            #expect(error.code == .notFound)
            #expect(error.message == "no task with id \"ghost\"")
        }
        // 自动生成的 id 形状合法且与既有 id 不同。
        _ = try service.addDynamicTask(["prompt": .string("自动 id"), "every": .int(60)])
        let generated = try #require(service.tasks.last)
        #expect(generated.id.wholeMatch(of: /^task-[0-9a-z]+-[0-9a-z]{4}$/) != nil)
        #expect(generated.id != "a")
    }
}
