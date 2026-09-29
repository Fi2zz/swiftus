import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusCron
import Testing

/// S9 运行时单元测试：tick 节奏（首 tick 延迟 / 固定间隔 / dispose 取消 / 重入跳过）、
/// 交付端口拿到的活任务与 framing、通知端口文案。
///
/// 全部用手动时间驱动，**零真实等待**。
@Suite("S9 运行时与交付")
struct S9RuntimeTimerTests {
    /// 固定墙钟：`now` 变量推进（tick 的到期判定全靠它）。
    private let start = CronInstant.parse("2026-03-09T10:00:00Z")!

    @ContextTreeActor
    private func makeService(
        driver: ManualTimerDriver,
        now: @escaping @Sendable () -> Date,
        storage: any CronStorage = MemoryCronStorage()
    ) -> CronService {
        CronService(
            storage: storage,
            timeZone: TimeZone(identifier: "UTC")!,
            clock: now,
            entropy: { _ in 1 }
        )
    }

    @Test("首 tick 在 firstTickDelay 之后，间隔 tick 按 tickSeconds 触发")
    @ContextTreeActor
    func tickSchedule() async throws {
        let driver = ManualTimerDriver()
        let wallClock = DateBox(self.start)
        let box = Counter()
        let service = makeService(driver: driver, now: { wallClock.now })
        // `every: 10` 从未运行过 → 锚点是装配时刻，间隔随墙钟推进反复到期。
        _ = try service.addDynamicTask([
            "id": .string("t"), "prompt": .string("干活"), "every": .int(10),
        ])
        let runtime = CronRuntime(
            service: service,
            deliver: { _, _, _ in box.bump(); return true },
            options: CronRuntimeOptions(
                clock: { wallClock.now },
                driver: driver,
                tickSeconds: 15,
                firstTickDelay: .seconds(3)
            )
        )
        // 装配后两个定时器都挂上了（首 tick + 周期 tick）。
        try await driver.awaitWaiters(2)
        // 墙钟先越过第一个间隔（10 秒）→ 任务已到期，此时才轮到「谁来发现它」。
        wallClock.advance(11)
        advance(driver, wallClock, .seconds(2))
        try await s9Eventually("未到首 tick 延迟不触发") { box.value == 0 }
        advance(driver, wallClock, .seconds(1))
        try await s9Eventually("首 tick 到点触发一次") { box.value == 1 }
        // 周期 tick：15 秒一次；墙钟同步推进让 every 任务再次到期。
        advance(driver, wallClock, .seconds(15))
        try await s9Eventually("周期 tick 触发") { box.value == 2 }
        advance(driver, wallClock, .seconds(15))
        try await s9Eventually("周期 tick 再触发") { box.value == 3 }
        // 停用后即使到点也不再交付。
        _ = try service.setEnabled("t", false)
        wallClock.advance(120)
        advance(driver, wallClock, .seconds(60))
        try await s9Eventually("停用后不再交付") { box.value == 3 }
        runtime.dispose()
    }

    @Test("dispose 取消两个定时器且幂等")
    @ContextTreeActor
    func disposeCancels() async throws {
        let driver = ManualTimerDriver()
        let box = Counter()
        let service = makeService(driver: driver, now: { self.start })
        let runtime = CronRuntime(
            service: service,
            deliver: { _, _, _ in box.bump(); return true },
            options: CronRuntimeOptions(
                clock: { self.start },
                driver: driver,
                tickSeconds: 15,
                firstTickDelay: .seconds(3)
            )
        )
        try await driver.awaitWaiters(2)
        runtime.dispose()
        runtime.dispose() // 幂等
        try await s9Eventually("dispose 后等待者被取消") { driver.pending == 0 }
        driver.advance(.seconds(600))
        try await s9Eventually("dispose 后不再触发") { box.value == 0 }
    }

    @Test("tickSeconds < 1 按 1 处理")
    @ContextTreeActor
    func tickSecondsFloor() async throws {
        let driver = ManualTimerDriver()
        let wallClock = DateBox(self.start)
        let box = Counter()
        let service = makeService(driver: driver, now: { wallClock.now })
        _ = try service.addDynamicTask([
            "id": .string("t"), "prompt": .string("干活"), "at": .string("2026-03-09T09:00:00Z"),
        ])
        let runtime = CronRuntime(
            service: service,
            deliver: { _, _, _ in box.bump(); return true },
            options: CronRuntimeOptions(
                clock: { wallClock.now },
                driver: driver,
                tickSeconds: 0,
                firstTickDelay: .seconds(3600)
            )
        )
        try await driver.awaitWaiters(2)
        // 周期按 1 秒走（不是 0 秒忙轮询）。
        advance(driver, wallClock, .seconds(1))
        try await s9Eventually("按 1 秒周期触发") { box.value == 1 }
        runtime.dispose()
    }

    @Test("同一时刻只跑一个 tick：重入直接跳过")
    @ContextTreeActor
    func reentrancySkipped() async throws {
        let driver = ManualTimerDriver()
        let overlap = Counter()
        let service = makeService(driver: driver, now: { self.start })
        _ = try service.addDynamicTask([
            "id": .string("t"), "prompt": .string("干活"), "at": .string("2026-03-09T09:00:00Z"),
        ])
        // 交付端口在被调用时重入一次 tick：本轮还没跑完，应被跳过。
        // 运行时在闭包里自引用，用盒子持有（隐式解包可选值会让编译器崩）。
        let box = RuntimeBox()
        let runtime = CronRuntime(
            service: service,
            deliver: { _, _, _ in
                overlap.bump()
                if overlap.value == 1 {
                    await box.runtime?.tick()
                }
                return true
            },
            options: CronRuntimeOptions(
                clock: { self.start },
                driver: driver,
                tickSeconds: 15,
                firstTickDelay: .seconds(3)
            )
        )
        box.runtime = runtime
        try await driver.awaitWaiters(2)
        driver.advance(.seconds(3))
        try await s9Eventually("首 tick 触发") { overlap.value == 1 }
        // 重入的那次被跳过 → 任务只交付一次（历史条数停在 1）。
        try await s9Eventually("重入 tick 被跳过") { overlap.value == 1 }
        #expect(service.listHistory().count == 1, "重入的 tick 不应再次扫描任务")
        runtime.dispose()
    }

    @Test("交付端口拿到活的 task 与逐字 framing；finishRun 发系统通知")
    @ContextTreeActor
    func deliveryPayloadAndNotifier() async throws {
        let driver = ManualTimerDriver()
        let service = makeService(driver: driver, now: { self.start })
        _ = try service.addDynamicTask([
            "id": .string("t-1"),
            "prompt": .string("把昨天的会议纪要发出去"),
            "every": .int(60),
            "sessionId": .string("s9"),
        ])
        let seen = DeliveryBox()
        let notifier = NotificationBox()
        let runtime = CronRuntime(
            service: service,
            deliver: { recordId, framing, task in
                seen.record(recordId: recordId, framing: framing, task: task)
                return true
            },
            options: CronRuntimeOptions(
                clock: { self.start },
                driver: driver,
                notifier: notifier,
                tickSeconds: 15,
                firstTickDelay: .seconds(3)
            )
        )
        // every 60 秒尚未到间隔 → 不触发。
        try await driver.awaitWaiters(2)
        driver.advance(.seconds(3))
        try await s9Eventually("未到间隔不交付") { seen.calls.isEmpty }

        // runTaskNow：宿主手动触发，走同一条交付路径。
        let record = try await runtime.runTaskNow("t-1")
        #expect(seen.calls.count == 1)
        #expect(seen.calls[0].recordId == record.id)
        #expect(seen.calls[0].taskId == "t-1")
        #expect(seen.calls[0].sessionId == "s9")
        #expect(seen.calls[0].framing.hasPrefix("[cron] Scheduled task \"t-1\" fired."))
        #expect(seen.calls[0].framing.contains("<task>\n把昨天的会议纪要发出去\n</task>"))
        #expect(seen.calls[0].framing.contains("not a message from the user"))

        // finishRun 推进状态并发通知。
        let finished = runtime.finishRun(record.id, ok: true, excerpt: "已发出，共 3 封")
        #expect(finished?.status == .completed)
        #expect(notifier.calls.count == 1)
        #expect(notifier.calls[0].title == "定时任务完成：把昨天的会议纪要发出去")
        #expect(notifier.calls[0].body == "已发出，共 3 封")
        #expect(notifier.calls[0].taskId == "t-1")

        // 失败走另一条标题；无摘要时正文回落 prompt。
        let failed = runtime.finishRun(record.id, ok: false)
        #expect(failed?.status == .failed)
        #expect(notifier.calls[1].title == "定时任务失败：把昨天的会议纪要发出去")
        #expect(notifier.calls[1].body == "已发出，共 3 封", "无新摘要时保留已有摘要")

        // 未知记录：静默返回 nil，不发通知。
        #expect(runtime.finishRun("run-999-x", ok: true) == nil)
        #expect(notifier.calls.count == 2)
        runtime.dispose()
    }

    @Test("历史封顶 500、摘要截断 300、limit 退化")
    @ContextTreeActor
    func historyCaps() async throws {
        let storage = MemoryCronStorage()
        // 账本是「追加即整体重写」，逐条追加 520 次是 O(n²) 的文件 IO（测试要跑 20 秒）。
        // 改成从一份已满的账本起步：预置 500 条（seq 0…499），再追加 3 条验证裁剪与续接。
        storage.seedHistory((0..<kCronMaxHistory).map { seq in
            JSONValue.object(CronRunRecord(
                id: "run-\(seq)-seed",
                seq: seq,
                taskId: "seed-\(seq)",
                prompt: "旧的",
                sessionId: nil,
                scheduledFor: self.start,
                firedAt: self.start,
                status: .delivered
            ).json)
        })
        let service = makeService(driver: ManualTimerDriver(), now: { self.start }, storage: storage)
        let instant = self.start
        for index in 0..<3 {
            let ref = service.allocateRecordRef(instant)
            _ = service.commitFire(ref: ref, taskId: "t\(index)", slot: instant, firedAt: instant)
        }
        #expect(storage.savedHistory.count == kCronMaxHistory, "超过上限从头部裁剪")
        #expect(service.listHistory(limit: nil).count == 100, "缺省 limit → 100")
        #expect(service.listHistory(limit: 0).count == 100, "非法 limit → 100")
        #expect(service.listHistory(limit: 3).count == 3)
        #expect(service.listHistory(limit: 9999).count == 500, "超上限 → 封顶 500")
        // 最新在前：最后一条是 t2；最老的 3 条已被裁掉。
        #expect(service.listHistory(limit: 1).first?.taskId == "t2")
        #expect(!service.listHistory(limit: 500).contains { $0.taskId == "seed-0" })

        let last = service.allocateRecordRef(instant)
        let record = service.commitFire(ref: last, taskId: "long", slot: instant, firedAt: instant)
        #expect(record.seq == kCronMaxHistory + 3, "seq 从磁盘最大 seq 续接")
        let finished = service.finishRun(record.id, ok: true, excerpt: String(repeating: "长", count: 400))
        #expect(finished?.excerpt?.count == kCronExcerptLength)
    }

    @Test("seq 单调连续：交付被拒时归还，跨「重启」从最大 seq 续接")
    @ContextTreeActor
    func seqContinuity() async throws {
        let storage = MemoryCronStorage()
        let service = makeService(driver: ManualTimerDriver(), now: { self.start }, storage: storage)
        let first = service.allocateRecordRef(self.start)
        service.releaseRecordRef(first)
        let second = service.allocateRecordRef(self.start)
        #expect(first.seq == 0 && second.seq == 0, "归还是最新分配的那次，seq 保持连续")
        _ = service.commitFire(ref: second, taskId: "t", slot: self.start, firedAt: self.start)

        // 新服务从磁盘续接。
        let restored = makeService(driver: ManualTimerDriver(), now: { self.start }, storage: storage)
        let resumed = restored.allocateRecordRef(self.start)
        #expect(resumed.seq == 1, "加载时从最大 seq 续接")
    }
}

// MARK: - 辅助

/// 可推进的墙钟（与手动时间驱动同步推进；`every` 任务靠它才会再次到期）。
final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// 推进手动时间驱动，并让墙钟同步前进（tick 节奏与墙钟是两条独立的时间轴）。
func advance(_ driver: ManualTimerDriver, _ wallClock: DateBox, _ amount: Duration) {
    let components = amount.components
    wallClock.advance(TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18)
    driver.advance(amount)
}

/// 运行时自引用盒（交付端口里要重入同一个运行时）。
final class RuntimeBox: @unchecked Sendable {
    var runtime: CronRuntime?
}

/// 交付端口收到的内容盒（`@Sendable` 闭包不能捕获 `var` 数组）。
final class DeliveryBox: @unchecked Sendable {
    struct Call {
        let recordId: String
        let framing: String
        let taskId: String
        let sessionId: String?
    }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    func record(recordId: String, framing: String, task: CronTask) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(Call(recordId: recordId, framing: framing, taskId: task.id, sessionId: task.sessionId))
    }
}

/// 通知端口替身。
final class NotificationBox: CronNotifier, @unchecked Sendable {
    struct Call {
        let title: String
        let body: String
        let taskId: String?
    }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    func notify(title: String, body: String, taskId: String?) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(Call(title: title, body: body, taskId: taskId))
    }
}

/// 计数器。
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func bump() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}

/// 有界等待条件成立（不用固定次数 `Task.yield()`——那是靠不住的 settling）。
func s9Eventually(
    _ what: String,
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("超时：\(what)")
            return
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}
