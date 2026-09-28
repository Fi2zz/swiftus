import Foundation
import SwiftusCore

/// 到期运行时（规格 S8 §10.2）：把到期提醒交付进会话，并安排下一次唤醒。
///
/// 一次推导的顺序固定：等待检查点 → 折叠 → 采样墙钟 → 交付 → 交付成功后才追加
/// dispatch → 再等待检查点。交付失败或拒绝投递时不写 dispatch，记录保持活动。
@ContextTreeActor
public final class ScheduleRuntime {
    /// 提供提醒状态与持久化检查点的服务。
    public let schedule: SessionSchedule
    /// 把 framing 文本投递进会话的端口。
    public let deliver: ScheduleDelivery

    private let clock: @Sendable () -> Date
    private let wakeClock: any Clock<Duration>
    private let onWarning: ((String) -> Void)?

    private var timerTask: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var requested = false
    private var disposed = false
    private var faulted = false

    /// 构造一个运行时；经 `requestDrive()` 触发首次推导。
    public init(
        schedule: SessionSchedule,
        deliver: @escaping ScheduleDelivery,
        config: ScheduleRuntimeConfig = ScheduleRuntimeConfig()
    ) {
        self.schedule = schedule
        self.deliver = deliver
        clock = config.clock
        wakeClock = config.wakeClock
        onWarning = config.onWarning
    }

    /// 请求一次推导：取消当前定时器，并合并到正在进行的推导上。
    public func requestDrive() {
        guard !disposed, !faulted else { return }
        clearTimer()
        requested = true
        guard running == nil else { return }
        running = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// 释放运行时：停止新工作并取消定时器，但不删除任何持久记录。幂等。
    public func dispose() async {
        guard !disposed else { return }
        disposed = true
        requested = false
        clearTimer()
        _ = await running?.value
    }

    /// 推导循环：请求位清零 → 推导一次，直至无新请求；结束后有需要则重驱。
    private func runLoop() async {
        while requested, !disposed, !faulted {
            requested = false
            await driveOnce()
        }
        running = nil
        if requested, !disposed, !faulted {
            requestDrive()
        }
    }

    private func driveOnce() async {
        clearTimer()
        guard !disposed, await preflightPassed() else { return }
        guard !disposed, let (decision, wakeNow) = decideDue() else { return }
        if case let .wait(target) = decision {
            if let target {
                arm(target, now: wakeNow)
            }
            return
        }
        await deliverDue(decision)
    }

    /// 持久化预检：失败只告警并放弃本轮。
    private func preflightPassed() async -> Bool {
        do {
            try await schedule.checkpoint(ScheduleOperation.list)
            return true
        } catch {
            warn("schedule: preflight failed: \(error)")
            return false
        }
    }

    /// 折叠 + 采样墙钟 + 到期决策；日志损坏置 faulted，其余失败只告警。
    private func decideDue() -> (DueDecision, Date)? {
        let folded: ScheduleFold
        do {
            folded = try schedule.fold()
        } catch {
            faulted = true
            warn("schedule: corrupt schedule log: \(error)")
            return nil
        }
        let wakeNow = clock()
        do {
            return (try dueDecision(folded, wakeNow), wakeNow)
        } catch {
            warn("schedule: due decision failed: \(error)")
            return nil
        }
    }

    /// 交付一批到期决策；faulted 停派发，dispatched 立即续推。
    private func deliverDue(_ decision: DueDecision) async {
        let outcome = await deliverDueDecision(
            decision: decision,
            schedule: schedule,
            deliver: deliver,
            onWarning: onWarning
        )
        if outcome == .faulted {
            faulted = true
            clearTimer()
            return
        }
        if outcome == .dispatched, !disposed {
            requestDrive()
        }
    }

    /// 武装定时器：分段上限 kMaxTimerSegmentMilliseconds；触发即重新推导（重新采样墙钟）。
    private func arm(_ target: Date, now: Date) {
        let remaining = target.timeIntervalSince(now)
        guard remaining > 0 else { return }
        let capped = min(remaining, Double(kMaxTimerSegmentMilliseconds) / 1000)
        timerTask = Task { [weak self, wakeClock] in
            try? await wakeClock.sleep(for: .seconds(capped))
            guard !Task.isCancelled else { return }
            self?.timerFired()
        }
    }

    private func timerFired() {
        timerTask = nil
        requestDrive()
    }

    private func clearTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func warn(_ message: String) {
        onWarning?(message)
    }
}

/// 运行时的可调旋钮（构造参数封装）。
public struct ScheduleRuntimeConfig {
    /// 墙钟采样（缺省系统时钟；测试注入固定推进）。
    public var clock: @Sendable () -> Date = Date.init
    /// 定时器睡眠时钟（缺省 ContinuousClock；测试可注入受控 Clock）。
    public var wakeClock: any Clock<Duration> = ContinuousClock()
    /// 可容错失败的告警回调。
    public var onWarning: ((String) -> Void)?

    public init() {}
}

/// 'scheduleRuntime' 服务键。
extension ServiceKey where Service == ScheduleRuntime {
    public static let scheduleRuntime = ServiceKey<ScheduleRuntime>("scheduleRuntime")
}

/// 把 ScheduleRuntime 作为 `scheduleRuntime` 服务提供到上下文并立即推导一次
/// （规格 S8 §10.2）。运行时随上下文释放而停止，不删除任何持久记录。
@ContextTreeActor
@discardableResult
public func provideScheduleRuntime(
    _ ctx: Context,
    deliver: @escaping ScheduleDelivery,
    config: ScheduleRuntimeConfig = ScheduleRuntimeConfig()
) throws -> ScheduleRuntime {
    guard let schedule = ctx.get(.schedule) else {
        throw ContextError.serviceUnavailable(key: "schedule", context: ctx.name)
    }
    let runtime = ScheduleRuntime(schedule: schedule, deliver: deliver, config: config)
    try ctx.provide(.scheduleRuntime, runtime)
    ctx.onDispose {
        Task { await runtime.dispose() }
    }
    runtime.requestDrive()
    return runtime
}
