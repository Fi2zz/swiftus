import Foundation
import SwiftusCore
import SwiftusFoundation

/// 交付端口：把 `framing` 与原始任务一起交给 `recordId` 关联的运行，返回是否成功入队。
///
/// 闭包与 cron 运行时**同隔离域**（`@ContextTreeActor`），因此能拿到活的
/// `CronTask`（可读 id / prompt / sessionId），同时不必把可变记录标成 Sendable。
/// 返回假表示当前无法投递：运行时归还记录标识、不写运行戳，下个 tick 重试。
/// 端口声明为 `throws`：宿主实现可以抛错（如目标会话已关闭），语义与来源一致。
public typealias CronDelivery = @ContextTreeActor (String, String, CronTask) async throws -> Bool

/// 默认 tick 间隔（秒）。
public let kDefaultCronTickSeconds = 15

/// 运行时选项（规格 S9 §8）。
public struct CronRuntimeOptions: Sendable {
    /// 墙钟；缺省 `Date.init`。
    public var clock: @Sendable () -> Date
    /// 时间缝；测试注入可手动推进的驱动。
    public var driver: any TimerDriver
    /// 系统通知端口；缺省不通知。
    public var notifier: (any CronNotifier)?
    /// tick 间隔秒数；小于 1 时按 1 处理。
    public var tickSeconds: Int
    /// 启动后到首次 tick 的延迟（让装配完成）。
    public var firstTickDelay: Duration
    /// 告警回调；缺省静默。
    public var onWarning: (@Sendable (String) -> Void)?

    public init(
        clock: @escaping @Sendable () -> Date = Date.init,
        driver: any TimerDriver = SystemTimerDriver(),
        notifier: (any CronNotifier)? = nil,
        tickSeconds: Int = kDefaultCronTickSeconds,
        firstTickDelay: Duration = .seconds(3),
        onWarning: (@Sendable (String) -> Void)? = nil
    ) {
        self.clock = clock
        self.driver = driver
        self.notifier = notifier
        self.tickSeconds = tickSeconds
        self.firstTickDelay = firstTickDelay
        self.onWarning = onWarning
    }
}

/// cron 定时运行时：扫描到期任务并交付给宿主注入的端口（规格 S9 §8）。
///
/// 启动后 `firstTickDelay` 首 tick，之后每 `tickSeconds` 一次；**每个任务独立
/// 隔离**，单任务故障只告警不影响其他；同一时刻只允许一个 tick 在跑（重入直接
/// 跳过）；`dispose()` 幂等，取消两个定时器、进行中的交付自然结束、不再触发新 tick。
@ContextTreeActor
public final class CronRuntime {
    /// cron 服务（任务与历史的权威状态）。
    public let service: CronService
    /// 交付端口。
    public let deliver: CronDelivery

    private let clock: @Sendable () -> Date
    private let driver: any TimerDriver
    private let notifier: (any CronNotifier)?
    private let onWarning: (@Sendable (String) -> Void)?
    private let tickSeconds: Int

    private var firstTask: Task<Void, Never>?
    private var intervalTask: Task<Void, Never>?
    private var disposedFlag = false
    private var ticking = false

    /// 构造并启动定时器；告警缺省走服务的同一通道。
    public init(
        service: CronService,
        deliver: @escaping CronDelivery,
        options: CronRuntimeOptions = CronRuntimeOptions()
    ) {
        self.service = service
        self.deliver = deliver
        clock = options.clock
        driver = options.driver
        notifier = options.notifier
        tickSeconds = max(1, options.tickSeconds)
        onWarning = options.onWarning ?? service.onWarning
        arm(firstDelay: options.firstTickDelay)
    }

    /// 扫描一轮全部任务，交付到期者。
    public func tick() async {
        // 重入的 tick 直接跳过：同一时刻只允许一个 tick 在跑。
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        let now = clock()
        let startedAt = service.startedAt
        // 逐任务隔离在 `fire` 内：交付端口抛错在那里被就地捕获并告警，
        // 因此一个任务投递失败不会中断本轮对其余任务的扫描。
        for task in service.tasks {
            if disposedFlag { return }
            if let slot = cronDueSlot(of: task, now: now, startedAt: startedAt, zone: service.timeZone) {
                await fire(task, slot)
            }
        }
    }

    /// 立即交付一个任务（宿主手动触发）；任务不存在抛 `not-found`，
    /// 投递不可用抛 `delivery-unavailable`。
    @discardableResult
    public func runTaskNow(_ id: String) async throws -> CronRunRecord {
        guard let task = service.findTask(id) else {
            throw CronException(.notFound, "no task with id \"\(id)\"")
        }
        guard let record = await fire(task, clock()) else {
            throw CronException(.deliveryUnavailable, "no delivery target is available to receive the task")
        }
        return record
    }

    /// 一轮执行完成后由装配方调用：推进记录状态并按结果发系统通知。
    @discardableResult
    public func finishRun(_ recordId: String, ok: Bool, excerpt: String? = nil) -> CronRunRecord? {
        guard let record = service.finishRun(recordId, ok: ok, excerpt: excerpt) else { return nil }
        notifier?.notify(
            title: ok ? "定时任务完成：\(record.prompt)" : "定时任务失败：\(record.prompt)",
            body: record.excerpt ?? record.prompt,
            taskId: record.taskId
        )
        return record
    }

    /// 停止定时器；进行中的交付自然结束，不再触发新 tick（幂等）。
    public func dispose() {
        guard !disposedFlag else { return }
        disposedFlag = true
        firstTask?.cancel()
        firstTask = nil
        intervalTask?.cancel()
        intervalTask = nil
    }

    /// 交付一个到期任务；成功才写运行戳与历史，拒绝 / 抛错返回 nil（规格 S9 §8）。
    @discardableResult
    public func fire(_ task: CronTask, _ slot: Date) async -> CronRunRecord? {
        let firedAt = clock()
        let framing = renderCronTaskMessage(id: task.id, prompt: task.prompt, slot: slot, firedAt: firedAt)
        let ref = service.allocateRecordRef(firedAt)
        let accepted: Bool
        do {
            accepted = try await deliver(ref.id, framing, task)
        } catch {
            service.releaseRecordRef(ref)
            warn("cron: deliver failed for task \"\(task.id)\": \(error)")
            return nil
        }
        guard accepted else {
            service.releaseRecordRef(ref)
            warn("cron: task \"\(task.id)\" is due but delivery was refused; will retry next tick")
            return nil
        }
        return service.commitFire(ref: ref, taskId: task.id, slot: slot, firedAt: firedAt)
    }

    private func arm(firstDelay: Duration) {
        let driver = self.driver
        let interval = Duration.seconds(tickSeconds)
        firstTask = Task { [weak self] in
            do {
                try await driver.wait(firstDelay)
            } catch {
                return // 等待被取消（dispose / 上下文释放）→ 不触发
            }
            guard let self, !Task.isCancelled, !self.disposedFlag else { return }
            await self.runScheduledTick()
        }
        intervalTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await driver.wait(interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled, !self.disposedFlag else { return }
                await self.runScheduledTick()
            }
        }
    }

    private func runScheduledTick() async {
        guard !ticking else { return }
        await tick()
    }

    private func warn(_ message: String) {
        onWarning?(message)
    }
}
