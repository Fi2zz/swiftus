import Foundation
import SwiftusCore
import SwiftusFoundation

/// 受控时间驱动：手动推进「现在」并放行等待者（规格 S19 §6 的时间缝，S9 运行时复用）。
///
/// 与 `SwiftusFoundationTests` 里的同名驱动是同一份实现的副本——SwiftPM 不支持
/// 一个文件同时属于两个 test target，故按仓内既有惯例（`Counter` / `LineBox` 同款）
/// 在各 target 内各留一份，改动时同步。
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
}

/// 手动驱动的失败形态（超时类）。
enum ManualTimerError: Error, Equatable {
    case waiterTimeout(expected: Int, actual: Int)
    case conditionTimeout(label: String)
}
