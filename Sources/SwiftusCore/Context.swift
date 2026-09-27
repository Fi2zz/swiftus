/// 统一上下文：同时承载**效应**（可逆副作用）与**共效应**（声明式依赖）（规格 S2）。
///
/// 上下文组成一棵树，整树共享同一个 Reactor。服务沿父链向下可见，反之不成立；
/// 父释放级联释放子树。上下文必须显式 `dispose()`（Dart 靠 GC 收尾，
/// Swift ARC 下未释放的上下文表现为效应泄漏，框架内自引用闭包均为弱引用防环）。
@ContextTreeActor
public final class Context {
    let reactor: Reactor
    let scope = EffectScope()
    private var services: [String: ServiceEntry] = [:]
    private var nextServiceToken: UInt64 = 0
    private weak var _parent: Context?

    /// 上下文名称，用于调试与日志。
    public let name: String

    private struct ServiceEntry {
        let token: UInt64
        let value: Any
    }

    init(parent: Context?, reactor: Reactor, name: String) {
        self._parent = parent
        self.reactor = reactor
        self.name = name
    }

    /// 创建一个根上下文。
    public static func root(name: String = "root") -> Context {
        Context(parent: nil, reactor: Reactor(), name: name)
    }

    /// 父上下文；根上下文为 nil。
    public var parent: Context? {
        _parent
    }

    /// 本上下文直接提供的服务键（不含继承）。
    public var localServiceKeys: [String] {
        Array(services.keys)
    }

    /// 上下文是否已释放。
    public var disposed: Bool {
        scope.disposed
    }

    // ══════════════════════════════════════════════════════════════
    // 服务（空间可组合性的载体）
    // ══════════════════════════════════════════════════════════════

    /// 沿父链查找服务；本上下文直接提供（含 nil 值）即短路返回，找不到返回 nil。
    public func get<S>(_ key: ServiceKey<S>) -> S? {
        guard let entry = services[key.id] else { return _parent?.get(key) }
        return entry.value as? S
    }

    /// 与 get 相同，但找不到时抛出 ContextError.serviceUnavailable。
    public func require<S>(_ key: ServiceKey<S>) throws -> S {
        guard let value = get(key) else {
            throw ContextError.serviceUnavailable(key: key.id, context: name)
        }
        return value
    }

    /// 服务是否可见（含继承）。
    public func contains(_ key: AnyServiceKey) -> Bool {
        services.keys.contains(key.id) || (_parent?.contains(key) ?? false)
    }

    /// 在当前上下文提供服务；重复提供或上下文已释放时抛错。
    /// 返回幂等 Disposer：撤销时令牌不匹配（键位已被更替）则不误删新值（S2 §2）。
    @discardableResult
    public func provide<S>(_ key: ServiceKey<S>, _ value: S?) throws -> Disposer {
        guard !scope.disposed else {
            throw ContextError.contextDisposed(key: key.id, context: name)
        }
        guard services[key.id] == nil else {
            throw ContextError.duplicateService(key: key.id, context: name)
        }
        nextServiceToken += 1
        let token = nextServiceToken
        services[key.id] = ServiceEntry(token: token, value: value as Any)
        try reactor.notify()

        var removed = false
        let disposer: Disposer = { [weak self] in
            guard let self, !removed else { return }
            removed = true
            guard self.services[key.id]?.token == token else { return }
            self.services.removeValue(forKey: key.id)
            try self.reactor.notify()
        }
        scope.track(disposer)
        return disposer
    }

    // ══════════════════════════════════════════════════════════════
    // 效应（时间可组合性）
    // ══════════════════════════════════════════════════════════════

    /// 登记一个撤销函数，上下文释放时按 LIFO 顺序执行。
    public func track(_ disposer: @escaping Disposer) {
        scope.track(disposer)
    }

    /// track 的语义化别名。
    public func onDispose(_ disposer: @escaping Disposer) {
        scope.track(disposer)
    }

    /// 执行 body；返回值为 Disposer 时自动登记。
    @discardableResult
    public func effect(_ body: @ContextTreeActor () throws -> Disposer) rethrows -> Disposer {
        try scope.capture(body)
    }

    /// 执行 body，原样返回其结果（不登记）。
    @discardableResult
    public func effect<T>(_ body: @ContextTreeActor () throws -> T) rethrows -> T {
        try scope.capture(body)
    }

    // ══════════════════════════════════════════════════════════════
    // 生命周期
    // ══════════════════════════════════════════════════════════════

    /// 释放上下文：撤销所有效应、移除所有服务、级联释放子树。幂等（S2 §5）。
    public func dispose() {
        disposeInternal()
    }

    /// 内部释放：撤销错误按 Dart 行为丢弃；尾部兜底清空残留服务并再广播一次。
    func disposeInternal() {
        _ = scope.dispose()
        guard !services.isEmpty else { return }
        services.removeAll()
        reactor.notifyOrReport()
    }
}

extension Context: CustomStringConvertible {
    public nonisolated var description: String {
        "Context(\(name))"
    }
}
