import Foundation
import SwiftusCore

/// 定时器的时间缝（规格 S19 §2 / §6 的 Clock 纪律）。
///
/// 生产实现走 `Task.sleep` + `ContinuousClock`；测试注入可手动推进的驱动，
/// 于是节流窗口、防抖窗口、超时中断都能在**不依赖真实墙钟**的前提下断言。
public protocol TimerDriver: Sendable {
    /// 等待一个间隔；抛错（通常是 `CancellationError`）表示等待被取消。
    func wait(_ interval: Duration) async throws

    /// 当前时刻（用于节流窗口计算）。
    func now() -> Duration
}

/// 生产实现：`Task.sleep` + `ContinuousClock`（单调钟，不读墙钟）。
public struct SystemTimerDriver: TimerDriver {
    /// 取时基准：节流窗口的「现在」是相对它的位移（Duration 是单调量）。
    private let reference: ContinuousClock.Instant

    public init() {
        reference = ContinuousClock().now
    }

    public func wait(_ interval: Duration) async throws {
        guard interval > .zero else { return }
        try await Task.sleep(for: interval)
    }

    public func now() -> Duration {
        ContinuousClock().now - reference
    }
}

/// 节流后的可调用包装（规格 S19 §2）：`call()` 触发调用，`dispose()` 取消挂起中的补执行。
@ContextTreeActor
public final class Throttled {
    private let callback: @ContextTreeActor () -> Void
    private let delay: Duration
    private let trailing: Bool
    private let driver: any TimerDriver
    private var pending: Task<Void, Never>?
    private var lastRun: Duration?
    private var disposedFlag = false

    init(
        callback: @escaping @ContextTreeActor () -> Void,
        delay: Duration,
        trailing: Bool,
        driver: any TimerDriver
    ) {
        self.callback = callback
        self.delay = delay
        self.trailing = trailing
        self.driver = driver
    }

    /// 触发一次调用。
    public func call() {
        guard !disposedFlag else { return }
        let now = driver.now()
        // 首次调用立即执行：没有上次执行时刻就没有窗口。
        guard let lastRun else {
            run(at: now)
            return
        }
        let elapsed = now - lastRun
        if elapsed >= delay {
            run(at: now)
        } else if trailing {
            // 窗口内被抑制：重置计时，在窗口结束时补执行一次。
            pending?.cancel()
            let remaining = delay - elapsed
            let driver = driver
            pending = Task { [weak self] in
                try? await driver.wait(remaining)
                guard let self, !Task.isCancelled else { return }
                self.run(at: self.driver.now())
            }
        }
    }

    /// 取消挂起中的定时器并停用该包装（幂等）；停用后 `call()` 不再执行。
    public func dispose() {
        guard !disposedFlag else { return }
        disposedFlag = true
        pending?.cancel()
        pending = nil
    }

    private func run(at now: Duration) {
        pending = nil
        lastRun = now
        callback()
    }
}

/// 防抖后的可调用包装（规格 S19 §2）：`call()` 重置计时，静默一个 delay 后执行。
@ContextTreeActor
public final class Debounced {
    private let callback: @ContextTreeActor () -> Void
    private let delay: Duration
    private let driver: any TimerDriver
    private var pending: Task<Void, Never>?
    private var disposedFlag = false

    init(callback: @escaping @ContextTreeActor () -> Void, delay: Duration, driver: any TimerDriver) {
        self.callback = callback
        self.delay = delay
        self.driver = driver
    }

    /// 触发一次调用（会重置计时）。
    public func call() {
        guard !disposedFlag else { return }
        pending?.cancel()
        let driver = driver
        let delay = delay
        pending = Task { [weak self] in
            try? await driver.wait(delay)
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.callback()
        }
    }

    /// 取消挂起中的执行并停用该包装（幂等）；停用后 `call()` 不再执行。
    public func dispose() {
        guard !disposedFlag else { return }
        disposedFlag = true
        pending?.cancel()
        pending = nil
    }
}

extension Context {
    /// 延迟 `delay` 后执行一次；返回的撤销函数可提前取消（规格 S19 §2）。
    ///
    /// 定时器登记在**本上下文**上，随上下文释放自动清理。
    @discardableResult
    public func timeout(
        _ callback: @escaping @ContextTreeActor () -> Void,
        after delay: Duration,
        driver: any TimerDriver = SystemTimerDriver()
    ) -> Disposer {
        // 登记为上下文效应：随上下文释放自动清理（规格 S19 §2）。
        return effect {
            let task = Task {
                do {
                    try await driver.wait(delay)
                } catch {
                    return // 等待被取消（撤销 / 上下文释放）→ 不执行
                }
                guard !Task.isCancelled else { return }
                callback()
            }
            return { task.cancel() }
        }
    }

    /// 每 `delay` 执行一次；返回的撤销函数可提前取消（规格 S19 §2）。
    @discardableResult
    public func interval(
        _ callback: @escaping @ContextTreeActor () -> Void,
        every delay: Duration,
        driver: any TimerDriver = SystemTimerDriver()
    ) -> Disposer {
        // 登记为上下文效应：随上下文释放自动清理（规格 S19 §2）。
        return effect {
            let task = Task {
                while !Task.isCancelled {
                    do {
                        try await driver.wait(delay)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    callback()
                }
            }
            return { task.cancel() }
        }
    }

    /// 等待 `delay`；**上下文在到点前被释放时以错误结束**，避免调用方悬挂（规格 S19 §2）。
    public func sleep(_ delay: Duration, driver: any TimerDriver = SystemTimerDriver()) async throws {
        let box = SleepBox()
        let name = self.name
        let off: Disposer = effect {
            let task = Task {
                do {
                    try await driver.wait(delay)
                    box.succeed()
                } catch {
                    // 等待被取消 = 上下文先被释放：明确报中断，不让调用方悬挂。
                    box.fail(ContextDisposedError(name: name))
                }
            }
            return { task.cancel() }
        }
        defer { try? off() }
        try await box.wait()
    }

    /// 节流：窗口内的重复调用最多执行一次（规格 S19 §2）。
    public func throttle(
        _ callback: @escaping @ContextTreeActor () -> Void,
        _ delay: Duration,
        trailing: Bool = true,
        driver: any TimerDriver = SystemTimerDriver()
    ) -> Throttled {
        let throttled = Throttled(callback: callback, delay: delay, trailing: trailing, driver: driver)
        track { throttled.dispose() }
        return throttled
    }

    /// 防抖：最后一次调用后静默 `delay` 才执行（规格 S19 §2）。
    public func debounce(
        _ callback: @escaping @ContextTreeActor () -> Void,
        _ delay: Duration,
        driver: any TimerDriver = SystemTimerDriver()
    ) -> Debounced {
        let debounced = Debounced(callback: callback, delay: delay, driver: driver)
        track { debounced.dispose() }
        return debounced
    }
}

/// 上下文提前释放导致 `sleep` 中断（规格 S19 §2）。
public struct ContextDisposedError: Error, Equatable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

extension ContextDisposedError: CustomStringConvertible {
    public var description: String {
        "上下文 \"\(name)\" 已释放，sleep 被中断。"
    }
}

/// `sleep` 的一次性落定盒（成功 / 失败各落定一次）。
final class SleepBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var result: Result<Void, any Error>?

    /// 等待落定：先到先得（成功 / 失败各落定一次）。
    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func succeed() {
        settle(.success(()))
    }

    func fail(_ error: any Error) {
        settle(.failure(error))
    }

    private func settle(_ result: Result<Void, any Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
