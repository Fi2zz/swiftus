import Foundation
import SwiftusCore

/// 收集器的回调钩子。
struct CollectorHooks {
    let providers: () -> [any SkillProvider]
    let runtime: () -> [SkillRegistration]
    let publish: ([SkillSummary]) -> Void
    let onWarning: (@ContextTreeActor (String) -> Void)?
}

/// 技能快照的收集器：标脏 → 合并窗口 → 串行收集 → 发布新快照（规格 S14 §4）。
///
/// invalidate 合并密集请求并调度一次收集；refresh 立即收集，且把并发调用
/// 共用成同一次（收集期间再次失效会在本轮结束后补一轮）。
@ContextTreeActor
final class SkillCollector {
    private let hooks: CollectorHooks
    private let debounce: TimeInterval

    private var timerTask: Task<Void, Never>?
    private var runningTask: Task<Void, Never>?
    private var pending = false
    private var disposed = false

    init(debounce: TimeInterval, hooks: CollectorHooks) {
        self.debounce = debounce
        self.hooks = hooks
    }

    /// 立即收集；收集期间的并发调用共用同一次收集。
    func refresh() async {
        guard !disposed else { return }
        if let runningTask {
            pending = true
            await runningTask.value
            return
        }
        let task = Task<Void, Never> { await runCycle() }
        runningTask = task
        await task.value
        runningTask = nil
        guard pending, !disposed else { return }
        pending = false
        await refresh()
    }

    /// 标记快照已过期并调度一次收集；合并窗口内的多次调用只收集一次。
    func invalidate() {
        guard !disposed else { return }
        timerTask?.cancel()
        timerTask = Task { [debounce, weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            } catch {
                return
            }
            await self?.refresh()
        }
    }

    /// 取消待执行的收集；此后再调用 refresh / invalidate 不再生效。
    func dispose() {
        disposed = true
        timerTask?.cancel()
        timerTask = nil
        pending = false
    }

    private func runCycle() async {
        let collected = await collectSkillSummaries(
            providers: hooks.providers(),
            runtime: hooks.runtime(),
            onWarning: hooks.onWarning
        )
        guard !disposed else { return }
        hooks.publish(collected)
    }
}
