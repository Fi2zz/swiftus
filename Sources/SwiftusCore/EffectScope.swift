/// 时间可组合性的实现：收集一组可逆副作用，按 LIFO 顺序统一撤销（规格 S1 §2）。
///
/// 关键性质：幂等（重复 dispose 只释放一次）、迟到登记安全（释放后 track 立即执行）、
/// 抗异常（单个撤销函数抛错不阻断其余，错误收集后返回）。
@ContextTreeActor
public final class EffectScope {
    private var disposers: [Disposer] = []

    /// 作用域是否已被释放。
    public private(set) var disposed = false

    /// 当前登记的撤销函数数量。
    public var length: Int {
        disposers.count
    }

    public init() {}

    /// 登记一个撤销函数；作用域已释放时立即执行（迟到登记安全），执行错误上报兜底通道。
    public func track(_ disposer: @escaping Disposer) {
        guard !disposed else {
            runImmediately(disposer)
            return
        }
        disposers.append(disposer)
    }

    /// 执行 body；返回值为 Disposer 时自动登记。
    @discardableResult
    public func capture(_ body: @ContextTreeActor () throws -> Disposer) rethrows -> Disposer {
        let disposer = try body()
        track(disposer)
        return disposer
    }

    /// 执行 body，原样返回其结果（不登记）。
    @discardableResult
    public func capture<T>(_ body: @ContextTreeActor () throws -> T) rethrows -> T {
        try body()
    }

    /// 按 LIFO 顺序执行全部撤销函数；单个错误不阻断其余，收集后返回（空数组 = 全部成功）。幂等。
    @discardableResult
    public func dispose() -> [any Error] {
        guard !disposed else { return [] }
        disposed = true
        var errors: [any Error] = []
        while let disposer = disposers.popLast() {
            do {
                try disposer()
            } catch {
                errors.append(error)
            }
        }
        return errors
    }

    private func runImmediately(_ disposer: Disposer) {
        do {
            try disposer()
        } catch {
            ContextRuntime.report(error)
        }
    }
}
