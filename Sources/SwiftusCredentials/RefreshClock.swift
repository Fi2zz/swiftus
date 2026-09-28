import Foundation
import SwiftusCore

/// 周期刷新的等待缝（规格 S12 §8）。
///
/// 落实「时间模块只接受注入的 Clock」纪律：生产用 `TaskRefreshClock`，
/// 测试注入受控等待器推进，不依赖真实墙钟。
public protocol RefreshClock: Sendable {
    /// 等待一个间隔（秒）；抛错表示等待被取消，周期任务随即结束。
    func wait(_ interval: TimeInterval) async throws

    /// 取消当前挂起的等待。
    ///
    /// **必须是协议要求（requirement）而非仅扩展方法**：扩展方法不走动态派发，
    /// 存在 `any RefreshClock` 上只会执行默认实现，替身的实现永远不会被调用
    /// （移植期实测踩过：受控时钟的取消钩子写了却收不到）。
    func cancelPendingWaits()
}

extension RefreshClock {
    /// 取消当前挂起的等待（默认无操作）。
    ///
    /// 生产实现的等待者是 `Task.sleep`，随 Task 取消自然结束；但**受控时钟**
    /// （测试替身）挂在 continuation 上，Task 取消不会唤醒它，故留这个钩子——
    /// 规格 S12 §8「close 取消周期任务」对两类等待者都要真的生效。
    public func cancelPendingWaits() {}
}

/// 生产实现：`Task.sleep`。
public struct TaskRefreshClock: RefreshClock {
    public init() {}

    public func wait(_ interval: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
    }
}

/// 周期刷新调度器（规格 S12 §8）：至多一个周期任务，`close` 取消。
///
/// 周期路径里的拉取失败**静默吞掉**（不打断后续调度）；显式调用方自己拿错误码。
@ContextTreeActor
final class RefreshScheduler {
    private let interval: TimeInterval?
    private let clock: any RefreshClock
    private var task: Task<Void, Never>?

    init(interval: TimeInterval?, clock: any RefreshClock) {
        self.interval = interval
        self.clock = clock
    }

    /// 首次拉取成功后调用；已有周期任务则不叠加。
    func schedule(_ refresh: @escaping @ContextTreeActor () async -> Void) {
        guard let interval, task == nil else { return }
        let clock = clock
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.wait(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await refresh()
            }
            _ = self
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        clock.cancelPendingWaits()
    }
}
