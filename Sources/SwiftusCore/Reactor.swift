/// 空间可组合性的调度核心：服务变更的同步广播器（规格 S1 §3）。
///
/// 采用「脏标记 + 重跑」策略处理重入：通知过程中又发生服务变更时，
/// 整个监听器列表重新评估一轮，直到收敛；超过 maxRounds 轮未收敛抛错（快速失败）。
@ContextTreeActor
public final class Reactor {
    /// 监听器签名。
    public typealias Listener = @ContextTreeActor () -> Void

    /// 监听器句柄：add 的返回值，用于 remove（Dart 闭包身份移除的对应物，见 S1 实现注记）。
    public struct ListenerToken: Hashable, Sendable {
        fileprivate let raw: Int
    }

    /// 单次 notify 允许的最大重跑轮数；超过则抛 convergenceFailed。
    public let maxRounds: Int

    private var listeners: [(token: ListenerToken, body: Listener)] = []
    private var broadcasting = false
    private var dirty = false
    private var nextToken = 0

    public init(maxRounds: Int = 100) {
        precondition(maxRounds > 0, "maxRounds 必须为正数")
        self.maxRounds = maxRounds
    }

    /// 是否正在广播中。
    public var running: Bool {
        broadcasting
    }

    /// 已登记的监听器数量。
    public var length: Int {
        listeners.count
    }

    /// 添加监听器；同一闭包可被重复添加，每次登记是一个独立实例。
    @discardableResult
    public func add(_ listener: @escaping Listener) -> ListenerToken {
        nextToken += 1
        let token = ListenerToken(raw: nextToken)
        listeners.append((token: token, body: listener))
        return token
    }

    /// 移除一个已登记的实例，返回是否确实移除了一个。
    @discardableResult
    public func remove(_ token: ListenerToken) -> Bool {
        guard let index = listeners.firstIndex(where: { $0.token == token }) else { return false }
        listeners.remove(at: index)
        return true
    }

    /// 触发一次广播。重入时仅置脏标记，由最外层循环重跑至收敛；
    /// 超过 maxRounds 轮仍未收敛抛 ContextError.convergenceFailed（循环依赖快速失败）。
    public func notify() throws {
        guard !broadcasting else {
            dirty = true
            return
        }
        broadcasting = true
        defer { broadcasting = false }
        var round = 0
        repeat {
            dirty = false
            round += 1
            if round > maxRounds {
                throw ContextError.convergenceFailed(maxRounds: maxRounds)
            }
            // 数组为值类型，for-in 迭代的是广播开始时的快照，
            // 监听器在回调中增删列表不引发并发修改（对应 Dart 的 List.of 快照）。
            for entry in listeners {
                entry.body()
            }
        } while dirty
    }

    /// notify 的非抛出变体：错误改投兜底通道（供 Disposer 等非抛出路径使用）。
    func notifyOrReport() {
        do {
            try notify()
        } catch {
            ContextRuntime.report(error)
        }
    }
}
