import Foundation
import SwiftusCore
import SwiftusCron
import SwiftusFoundation
import SwiftusSchedule
import SwiftusTasks
import Testing

/// 跨域接线验收：把「会话持久化 → 任务 → 提醒 → 定时任务」四段串进**同一条
/// SessionStore 写入链**，证明各自落地的事件最终落在同一份 JSONL 里。
///
/// 为什么要这条：S17 的 `task/changed`、S8 的 `schedule/change`、S4 的会话事件
/// 三者各自都有 fixtures，但「三段共享一条写入链、flush 一次落定、顺序不乱」这件
/// 事没有用例守着——接线错位时每个域的单测照样全绿。conatus 侧同样没有覆盖
/// （example/demo.dart 只接了会话，没接 tasks / schedule / cron）。
@Suite("跨域接线：会话 + 任务 + 提醒 + 定时任务")
struct CompositionWiringTests {

    @Test("四段事件共享一条 SessionStore 写入链，flush 一次落定、顺序不乱")
    @ContextTreeActor
    func sharedWriteChain() async throws {
        // 落盘到临时目录，验证「真的写进 JSONL」而不只是进了内存事件流。
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swiftus-composition-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try JsonlSessionPersistence(directory: directory.path())

        let app = Context.root(name: "composition")
        defer { app.dispose() }
        // 任务中心要往工具表注册 list_tasks / cancel_task，故工具表先就位。
        _ = try provideTools(app)
        let sessions = try provideSessions(app, persistence: persistence)
        let session = try sessions.create(id: "wiring")

        // ── 任务中心：事件直接写进这条会话（S17 §2）──
        var taskConfig = TaskCenterConfig()
        taskConfig.session = session
        let tasks = try provideTaskCenter(app, config: taskConfig)
        let created = try await tasks.create(kind: .agentTurn, description: "接线验收")

        // ── 提醒：同一条会话。S8 §2 说明提醒的唯一权威就是 `schedule/change` ──
        let schedule = try provideSessionSchedule(app, session: session)
        _ = try await schedule.create(prompt: "到点了", at: .string("2099-01-01T09:00:00Z"))

        // ── 定时任务：S9 自己的存储，不进会话事件流（另有 JSON 账本，见 §6）──
        let cronStorage = MemoryCronStorage()
        let cron = CronService(storage: cronStorage, timeZone: TimeZone(identifier: "UTC")!)
        _ = try cron.addDynamicTask([
            "prompt": .string("每日巡检"),
            "daily": .string("09:00"),
        ])
        let cronRuntime = CronRuntime(
            service: cron,
            // 交付端口：把到期的 prompt 送进**同一个会话**（与 S17 §7 的口径一致）。
            deliver: { recordId, framing, task in
                try session.append("cron/delivered", data: .object([
                    "recordId": .string(recordId),
                    "framing": .string(framing),
                    "prompt": .string(task.prompt),
                ]))
                return true
            },
            options: CronRuntimeOptions(
                clock: { Date(timeIntervalSince1970: 0) },
                driver: ManualTimerDriver(),
                tickSeconds: 15,
                firstTickDelay: .milliseconds(0)
            )
        )
        defer { cronRuntime.dispose() } // init 已 arm 首个 tick

        // ── 一次 flush 让全链落定 ──
        try await sessions.flush()

        // ── 断言：事件按发生顺序落在同一份 JSONL 里 ──
        let events = try await persistence.load("wiring")
        let kinds = events.map(\.type)
        #expect(!events.isEmpty, "flush 之后应有落盘事件")
        #expect(kinds.contains("task/changed"), "task/changed 应落盘，实际：\(kinds)")
        #expect(kinds.contains("schedule/change"), "schedule/change 应落盘，实际：\(kinds)")

        // 顺序：任务创建先于提醒创建。
        guard let taskIndex = kinds.firstIndex(of: "task/changed"),
              let scheduleIndex = kinds.firstIndex(of: "schedule/change") else {
            Issue.record("两类事件都应存在，实际：\(kinds)")
            return
        }
        #expect(taskIndex < scheduleIndex, "事件顺序应与发生顺序一致：\(kinds)")

        // 折叠回去（S17 的 restore / S8 的 fold）能还原出各自状态。
        try tasks.restore(session)
        #expect(tasks.get(created.id) != nil, "任务应能从会话事件流还原")
        let folded = try schedule.fold()
        #expect(folded.active.count == 1, "提醒应折叠回 1 条，实际 \(folded.active.count)")

        // 定时任务不进会话事件流：它有独立的 JSON 账本（S9 §6）。
        #expect(!kinds.contains("cron/changed"), "cron 事件走独立存储，不进会话")
        #expect(cronStorage.loadTasks().dynamicTasks.count == 1)
    }

    @Test("接线顺序无关：任务事件先落盘再还原，状态不丢")
    @ContextTreeActor
    func restoreAcrossReload() async throws {
        // 守的是「事件流是唯一权威」这条 S17 不变式：新建仓库重开会话，
        // 任务应从落盘事件里还原（执行环境已丢失 → 活跃任务标 failed）。
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "swiftus-reload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try JsonlSessionPersistence(directory: directory.path())

        let first = Context.root(name: "reload-1")
        defer { first.dispose() }
        _ = try provideTools(first)
        let firstStore = try provideSessions(first, persistence: persistence)
        let firstSession = try firstStore.create(id: "reload")
        var config = TaskCenterConfig()
        config.session = firstSession
        let center = try provideTaskCenter(first, config: config)
        let created = try await center.create(kind: .agentTurn, description: "跨重启")
        try await firstStore.flush()

        // 换一个全新的仓库（模拟进程重启），从同一份 JSONL 重开。
        let second = Context.root(name: "reload-2")
        defer { second.dispose() }
        _ = try provideTools(second)
        let secondStore = try provideSessions(second, persistence: persistence)
        let reopened = try await secondStore.open("reload")
        var restoreConfig = TaskCenterConfig()
        restoreConfig.session = reopened
        let restored = try provideTaskCenter(second, config: restoreConfig)
        try restored.restore(reopened)

        let task = try #require(restored.get(created.id), "任务应从事件流还原")
        // 执行环境已丢失，未完成任务标记为 failed（S17 §2 restore 协议）。
        #expect(task.status == .failed, "重开后活跃任务应标 failed，实际 \(task.status)")
        #expect(task.description == "跨重启")
    }
}

// MARK: - 测试替身

/// 内存 cron 存储（只为上面的断言保留最后快照）。
@ContextTreeActor
final class MemoryCronStorage: CronStorage {
    private var snapshot = CronStorageSnapshot.empty
    private var history: [JSONValue] = []

    func loadTasks() -> CronStorageSnapshot { snapshot }

    func saveTasks(
        tasks: [[String: JSONValue]],
        runStamps: [String: CronRunStamp],
        overrides: [String: Bool]
    ) {
        snapshot = CronStorageSnapshot(
            dynamicTasks: tasks,
            runStamps: runStamps,
            overrides: overrides
        )
    }

    func loadHistory() -> [JSONValue] {
        history
    }

    func saveHistory(_ records: [JSONValue]) {
        history = records
    }
}
