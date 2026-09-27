/// 共效应与插件：Context 的空间可组合性装配（规格 S2 §3 / §4）。
extension Context {
    /// 声明式依赖注入（S2 §3）。
    ///
    /// 依赖全部可见时在一个全新的子上下文中执行 callback；任一依赖消失时
    /// 该子上下文连同其所有效应被撤销；依赖重新齐全时在另一个全新子上下文再次执行。
    ///
    /// 返回幂等 Disposer：手动取消注入；该取消动作同时登记到宿主上下文，随宿主释放自动执行。
    @discardableResult
    public func inject(
        deps: [AnyServiceKey],
        _ callback: @escaping @ContextTreeActor (Context) throws -> Void
    ) -> Disposer {
        var seen = Set<AnyServiceKey>()
        let keys = deps.filter { seen.insert($0).inserted }

        var active: Context?
        var cancelled = false

        let evaluate: @ContextTreeActor () -> Void = { [weak self] in
            guard let self, !cancelled, !self.scope.disposed else { return }
            let ready = keys.allSatisfy { self.contains($0) }
            if ready, active == nil {
                let label = keys.map(\.id).joined(separator: "+")
                let child = Context(parent: self, reactor: self.reactor, name: "\(self.name)<\(label)>")
                active = child
                do {
                    try callback(child)
                } catch {
                    child.disposeInternal()
                    active = nil
                    ContextRuntime.report(error)
                }
            } else if !ready, let child = active {
                active = nil
                child.disposeInternal()
            }
        }

        let token = reactor.add(evaluate)
        evaluate()

        let canceller: Disposer = { [weak self] in
            guard let self, !cancelled else { return }
            cancelled = true
            _ = self.reactor.remove(token)
            let child = active
            active = nil
            child?.disposeInternal()
        }
        scope.track(canceller)
        return canceller
    }

    /// 加载一个插件：在派生的子上下文中执行 install，返回该子上下文句柄（S2 §4）。
    /// 子上下文登记到当前上下文，父释放时级联卸载；install 抛错时子上下文回滚并继续抛出。
    @discardableResult
    public func plugin(
        _ name: String,
        install: @ContextTreeActor (Context) throws -> Void
    ) rethrows -> Context {
        let child = Context(parent: self, reactor: reactor, name: "\(self)/\(name)")
        scope.track { child.disposeInternal() }
        do {
            try install(child)
        } catch {
            child.disposeInternal()
            throw error
        }
        return child
    }
}
