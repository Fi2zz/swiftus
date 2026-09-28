import Foundation
import SwiftusCore
import SwiftusFoundation
import Testing

/// 受控时间驱动：手动推进「现在」并放行等待者（规格 S19 §6 的时间缝）。
///
/// 让节流窗口、防抖窗口、超时中断都能在**零真实等待**的前提下断言。
final class ManualTimerDriver: TimerDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var clock: Duration = .zero
    /// 挂起的等待：`resume(nil)` 表示到点，`resume(CancellationError())` 表示被取消。
    private var waiters: [(id: Int, until: Duration, resume: @Sendable (Error?) -> Void)] = []
    private var nextId = 0

    /// 已放行的等待次数。
    private(set) var fired = 0
    /// 当前挂起的等待数。
    var pending: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func now() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return clock
    }

    func wait(_ interval: Duration) async throws {
        let id = nextId
        nextId += 1
        let deadline = now() + interval
        // 取消感知：`withCheckedThrowingContinuation` 本身不可取消，必须在
        // onCancel 里把等待者摘掉并以 CancellationError 结束——否则被撤销的
        // 定时器会永远挂住（生产实现走 Task.sleep，天然可取消）。
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                // 取消先于登记到达（竞态）：onCancel 已经错过这个等待者，
                // 此时必须自行落定，否则永远挂住。
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // 已到期（如 interval 为零或时钟已越过）：立刻落定。
                if deadline <= clock {
                    fired += 1
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append((id: id, until: deadline, resume: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: index)
                lock.unlock()
                waiter.resume(CancellationError())
            } else {
                lock.unlock()
            }
        }
    }

    /// 把时钟推进 `amount`，放行所有到点的等待者。
    func advance(_ amount: Duration) {
        lock.lock()
        clock += amount
        let due = waiters.filter { $0.until <= clock }
        waiters.removeAll { $0.until <= clock }
        fired += due.count
        lock.unlock()
        for waiter in due {
            waiter.resume(nil)
        }
    }

    /// 挂起中的等待数（诊断用）。
    var waiting: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    /// 有界等待「挂起数达到 count」；超时抛错（让用例失败，而不是挂死）。
    ///
    /// 推进时钟前必须先确认等待者已登记——否则推进会落空，随后新登记的等待者
    /// 起点被推高，断言与实际错位（本项目在移植期被这个竞态坑过一次）。
    func awaitWaiters(_ count: Int, timeout: Duration = .seconds(5)) async throws {
        let deadline = now() + timeout
        while pending < count {
            guard now() < deadline else {
                throw ManualTimerError.waiterTimeout(expected: count, actual: pending)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// 放行全部等待者（用于不关心具体时刻的收尾）。
    func advanceAll() {
        lock.lock()
        let remaining = waiters
        waiters = []
        fired += remaining.count
        lock.unlock()
        for waiter in remaining {
            waiter.resume(nil)
        }
    }
}

/// 有界等待某条件成立；超时抛错。
///
/// 用它代替「让出若干轮」的猜测式等待：脱离调用栈的任务何时跑到挂起点无法预知，
/// 固定轮次的 yield 会在负载下踩空，进而让断言与实际错位甚至挂死。
@discardableResult
func s19Eventually(
    _ label: String,
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () -> Bool
) async throws -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else {
            throw ManualTimerError.conditionTimeout(label: label)
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(2))
    }
    return true
}

/// 线程安全计数器：actor 隔离的局部 `var` 不能被 `@Sendable` 条件闭包捕获，
/// 故测试里的触发计数一律走这个盒子（与 LineBox 同款理由）。
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func bump(_ by: Int = 1) -> Int {
        lock.lock()
        storage += by
        let current = storage
        lock.unlock()
        return current
    }

    func set(_ next: Int) {
        lock.lock()
        storage = next
        lock.unlock()
    }
}

/// 手动驱动的失败形态（超时类）。
enum ManualTimerError: Error, Equatable {
    case waiterTimeout(expected: Int, actual: Int)
    case conditionTimeout(label: String)
}

@Suite("S19 单元：定时器时间缝")
@ContextTreeActor
struct TimerDriverTests {
    @Test("节流：窗口内合并并在窗口结束补执行一次")
    func throttleWindow() async throws {
        let ctx = Context.root()
        let driver = ManualTimerDriver()
        let fired = Counter()
        let throttled = ctx.throttle({ fired.bump() }, .seconds(1), driver: driver)

        throttled.call() // 首次立即执行
        #expect(fired.value == 1)
        throttled.call()
        throttled.call()
        #expect(fired.value == 1) // 窗口内被抑制
        try await driver.awaitWaiters(1) // 补执行的等待已登记

        driver.advance(.milliseconds(999))
        try await s19Eventually("窗口未到不补执行") { fired.value == 1 }
        #expect(fired.value == 1) // 未到窗口末尾

        driver.advance(.milliseconds(1))
        try await s19Eventually("窗口结束补执行一次") { fired.value == 2 }
        #expect(fired.value == 2) // 补执行一次

        driver.advance(.seconds(1))
        throttled.call()
        #expect(fired.value == 3) // 窗口已过，立即执行
        ctx.dispose()
    }

    @Test("节流 trailing=false：窗口内直接丢弃，不补执行")
    func throttleNoTrailing() async throws {
        let ctx = Context.root()
        let driver = ManualTimerDriver()
        let fired = Counter()
        let throttled = ctx.throttle({ fired.bump() }, .seconds(1), trailing: false, driver: driver)
        throttled.call()
        throttled.call()
        throttled.call()
        try await s19Eventually("节流无补执行") { true }
        driver.advance(.seconds(5))
        try await s19Eventually("trailing=false 不补执行") { true }
        #expect(fired.value == 1)
        ctx.dispose()
    }

    @Test("防抖：连续调用只执行一次，且以最后一次调用为准")
    func debounceCoalesce() async throws {
        let ctx = Context.root()
        let driver = ManualTimerDriver()
        let fired = Counter()
        let debounced = ctx.debounce({ fired.bump() }, .seconds(1), driver: driver)
        debounced.call()
        try await driver.awaitWaiters(1)
        driver.advance(.milliseconds(600))
        debounced.call() // 重置计时
        try await driver.awaitWaiters(1)
        driver.advance(.milliseconds(600))
        try await s19Eventually("重置后未到窗口不执行") { true }
        #expect(fired.value == 0) // 距最后一次调用还不满窗口
        driver.advance(.milliseconds(400))
        try await s19Eventually("静默期满执行一次") { fired.value == 1 }
        #expect(fired.value == 1)
        ctx.dispose()
    }

    @Test("dispose 幂等：停用后 call() 不再执行")
    func disposeIsIdempotent() async throws {
        let ctx = Context.root()
        let driver = ManualTimerDriver()
        let throttledFired = Counter()
        let debouncedFired = Counter()
        let throttled = ctx.throttle({ throttledFired.bump() }, .seconds(1), driver: driver)
        let debounced = ctx.debounce({ debouncedFired.bump() }, .seconds(1), driver: driver)
        throttled.dispose()
        throttled.dispose()
        debounced.dispose()
        debounced.dispose()
        throttled.call()
        debounced.call()
        driver.advanceAll()
        try await s19Eventually("dispose 后不执行") { true }
        #expect(throttledFired.value == 0)
        #expect(debouncedFired.value == 0)
        ctx.dispose()
    }

    @Test("timeout：撤销后不再触发；interval：上下文释放后停止")
    func timeoutAndInterval() async throws {
        let ctx = Context.root()
        let driver = ManualTimerDriver()
        let fired = Counter()
        let off: Disposer = ctx.timeout({ fired.bump() }, after: .seconds(1), driver: driver)
        try await driver.awaitWaiters(1)
        try? off()
        driver.advanceAll()
        try await s19Eventually("撤销后不触发") { driver.pending == 0 }
        #expect(fired.value == 0, "撤销后不应触发")

        let ctx2 = Context.root()
        let driver2 = ManualTimerDriver()
        let ticks = Counter()
        let off2: Disposer = ctx2.interval({ ticks.bump() }, every: .seconds(1), driver: driver2)
        // 逐拍推进：先等这一拍的等待已登记，再推进时钟，最后等回调落地（不猜时序）。
        for expected in 1...3 {
            try await driver2.awaitWaiters(1)
            driver2.advance(.seconds(1))
            try await s19Eventually("interval 第 \(expected) 拍") { ticks.value == expected }
        }
        #expect(ticks.value == 3)
        ctx2.dispose()
        try await s19Eventually("释放后等待者清空") { driver2.pending == 0 }
        driver2.advance(.seconds(5))
        try await s19Eventually("释放后不再触发") { true }
        #expect(ticks.value == 3, "上下文释放后不应再触发")
        try? off2()
        ctx.dispose()
    }

    @Test("sleep：上下文提前释放以 ContextDisposedError 结束")
    func sleepInterrupted() async throws {
        let ctx = Context.root()
        let driver = ManualTimerDriver()
        let sleeper = Task { @ContextTreeActor in
            try await ctx.sleep(.seconds(10), driver: driver)
        }
        try await driver.awaitWaiters(1)
        ctx.dispose()
        await #expect(throws: ContextDisposedError.self) {
            try await sleeper.value
        }
    }

    @Test("sleep：正常到点完成")
    func sleepCompletes() async throws {
        let ctx = Context.root()
        let driver = ManualTimerDriver()
        let sleeper = Task { @ContextTreeActor in
            try await ctx.sleep(.seconds(2), driver: driver)
        }
        try await driver.awaitWaiters(1)
        driver.advance(.seconds(2))
        try await sleeper.value
        ctx.dispose()
    }
}

@Suite("S19 单元：时间锚点的时区换算")
struct TimeContextTests {
    /// 非零偏移下的日期 / 星期换算（fixtures 只覆盖 UTC，见规格 S19 §6）。
    @Test("东八区：跨日的时刻按偏移换算成当地日期与星期")
    func eastEight() {
        // 2026-12-31T16:30Z 在 UTC+08:00 是 2027-01-01 00:30（周五）。
        let instant = ZonedInstant(
            date: Date(timeIntervalSince1970: 1_798_734_600),
            zoneName: "Asia/Shanghai",
            secondsFromGMT: 8 * 3600
        )
        let text = renderAnchor(instant)
        #expect(text == "[当前时间]\n2027-01-01 周五 · Asia/Shanghai (UTC+08:00)")
    }

    @Test("负偏移：西半球时刻按偏移换算")
    func westFive() {
        // 2026-07-05T04:30Z 在 UTC-05:00 是 2026-07-04 23:30（周六）。
        let instant = ZonedInstant(
            date: Date(timeIntervalSince1970: 1_783_225_800),
            zoneName: "America/Chicago",
            secondsFromGMT: -5 * 3600
        )
        let text = renderAnchor(instant)
        #expect(text == "[当前时间]\n2026-07-04 周六 · America/Chicago (UTC-05:00)")
    }

    @Test("半小时偏移按分钟补零")
    func halfHour() {
        let instant = ZonedInstant(
            date: Date(timeIntervalSince1970: 1_767_249_000),
            zoneName: "Asia/Kolkata",
            secondsFromGMT: 5 * 3600 + 1800
        )
        #expect(renderAnchor(instant).hasSuffix("Asia/Kolkata (UTC+05:30)"))
    }

    @Test("偏移格式化：正负号与补零")
    func offsets() {
        #expect(formatClockOffset(secondsFromGMT: 8 * 3600) == "+08:00")
        #expect(formatClockOffset(secondsFromGMT: -(5 * 3600 + 1800)) == "-05:30")
        #expect(formatClockOffset(secondsFromGMT: 0) == "+00:00")
        #expect(formatClockOffset(secondsFromGMT: 1800) == "+00:30")
        #expect(formatClockOffset(.seconds(-19_800)) == "-05:30")
    }

    @Test("未覆盖显示名时用系统时区缩写")
    @ContextTreeActor
    func systemZoneName() throws {
        let ctx = Context.root()
        let prompt = try provideSystemPrompt(ctx)
        let off: Disposer = try provideTimePrompt(ctx, prompt: prompt)
        let text = prompt.assemble().contexts.first { $0.name == kTimeContextName }?.text ?? ""
        try? off()
        ctx.dispose()
        // 锚点形状固定：名 + 偏移 + 日期行。
        #expect(text.hasPrefix("[当前时间]\n"))
        #expect(text.contains(" · "))
        #expect(text.contains("(UTC"))
        #expect(text.contains(" 周"))
    }
}

@Suite("S19 单元：database 写入链")
@ContextTreeActor
struct DatabaseUnitChainTests {
    /// 后端写失败：内存保持不变、不广播，异常原样上抛（规格 S19 §1.3 的关键不变式）。
    @Test("后端写失败时内存不领先介质")
    func writeFailureKeepsMemory() async throws {
        let hub = Database(defaultBackend: "boom")
        try hub.register("boom", FailingBackend())
        let unit = try await hub.open("u")
        var changes = 0
        let token = unit.onChange { _ in changes += 1 }

        await #expect(throws: DatabaseException.self) {
            try await unit.put("k", .string("v"))
        }
        #expect(unit.length == 0)
        #expect(unit.get("k") == nil)
        #expect(changes == 0, "落盘失败不应广播")

        // 换成正常后端后可写入。
        try hub.register("ok", StubBackend())
        let ok = try await hub.open("ok", backend: "ok")
        try await ok.put("k", .string("v"))
        #expect(ok.get("k") == .string("v"))
        #expect(changes == 0)
        unit.removeChangeListener(token)
    }

    /// delete 不存在：不落盘不广播（后端 save 次数不变）。
    @Test("删除不存在的键不落盘不广播")
    func deleteMissingIsNoop() async throws {
        let backend = StubBackend()
        let hub = Database(defaultBackend: "b")
        try hub.register("b", backend)
        let unit = try await hub.open("u")
        var changes = 0
        let token = unit.onChange { _ in changes += 1 }
        #expect(try await unit.delete("ghost") == false)
        #expect(changes == 0)
        try await unit.put("a", .int(1))
        #expect(changes == 1)
        #expect(try await unit.delete("a") == true)
        #expect(changes == 2)
        unit.removeChangeListener(token)
    }

    /// JSON 后端：原子写不留临时文件，整表可往返。
    @Test("JSON 后端原子发布不留临时文件")
    func jsonAtomic() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "swiftus-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = JsonDatabaseBackend(dir: dir.path)
        try await backend.save("u", ["a": .int(1), "b": .null])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["u.json"], "临时文件应已被 rename 消耗：\(names)")
        #expect(try await backend.load("u")["a"] == .int(1))
        try await backend.deleteUnit("u")
        #expect(try await backend.load("u").isEmpty)
    }
}

/// 总是写失败的后端（测试替身）。
@ContextTreeActor
final class FailingBackend: DatabaseBackend {
    func load(_ unit: String) async throws -> [String: JSONValue] {
        [:]
    }

    func save(_ unit: String, _ records: [String: JSONValue]) async throws {
        throw DatabaseException(.ioErrorStub, "介质不可写")
    }

    func deleteUnit(_ unit: String) async throws {}

    func close() async {}
}

@Suite("S19 单元：logger 与 loader 装配")
@ContextTreeActor
struct AssemblyTests {
    @Test("provideLogger：默认挂控制台导出器，上下文释放后摘除")
    func loggerAssembly() throws {
        let ctx = Context.root()
        let box = LineBox()
        let service = try provideLogger(ctx, level: .debug, writer: { box.append($0) })
        #expect(try ctx.require(.logger) === service)
        #expect(service.exporters.count == 1)
        service.info("hello")
        #expect(box.lines == ["[I] \(ctx.name)  hello"])
        ctx.dispose()
        #expect(service.exporters.isEmpty, "释放路径只摘本插件挂的导出器")
    }

    @Test("loader：禁用项仍登记但不加载插件；apply 逆序卸载")
    func loaderDisabledAndApply() throws {
        var log: [String] = []
        let ctx = Context.root()
        let loader = try provideLoader(ctx, plugins: [
            "p": { _, _ in log.append("on") },
        ])
        try loader.apply([
            LoaderEntry(id: "live", name: "p"),
            LoaderEntry(id: "off", name: "p", disabled: true),
        ])
        #expect(loader.ids == ["live", "off"])
        #expect(loader.contextOf("off") == nil, "禁用项不加载插件但仍登记")
        #expect(log == ["on"])

        try loader.apply([LoaderEntry(id: "fresh", name: "p")])
        #expect(loader.ids == ["fresh"])
        #expect(loader.contextOf("live") == nil)
        #expect(log == ["on", "on"])
    }

    @Test("loader：工厂抛错时子上下文回滚（entry 仍登记，与 Dart 一致）")
    func loaderPluginThrows() throws {
        var disposed = false
        let ctx = Context.root()
        let loader = try provideLoader(ctx, plugins: [
            "bad": { child, _ in
                child.track { disposed = true }
                throw LoaderException("boom")
            },
        ])
        #expect(throws: LoaderException.self) {
            try loader.load(LoaderEntry(id: "x", name: "bad"))
        }
        #expect(loader.contextOf("x") == nil, "install 抛错时子上下文回滚")
        #expect(disposed, "回滚要跑完已登记的撤销函数")
        // Dart 侧同样不清 entry（只对「未注册插件」摘 id），故此处照实断言。
        #expect(loader.ids == ["x"])
    }

    @Test("LoaderEntry JSON 往返：缺省字段不出现、disabled 保留")
    func entryRoundtrip() throws {
        let entry = LoaderEntry(
            id: "a",
            name: "p",
            config: .object(["k": .int(1)]),
            disabled: true,
            children: [LoaderEntry(name: "child")]
        )
        let json = entry.json
        #expect(json["children"] != nil)
        #expect(json["disabled"] == .bool(true))
        #expect(try LoaderEntry.from(json) == entry)

        // 缺省字段不出现（与 Dart 的 toJson 同形：键直接缺失，不是 null）。
        let bare = LoaderEntry(name: "p").json
        #expect(bare["id"] == nil)
        #expect(bare["config"] == nil)
        #expect(bare["disabled"] == nil)
        #expect(bare["children"] == nil)
        #expect(try LoaderEntry.from(bare).isGroup == false)
    }
}

extension DatabaseException.Code {
    /// 测试替身专用的写失败码（协议外的注入点，仅测试使用）。
    fileprivate static let ioErrorStub = DatabaseException.Code.malformedMedium
}
