import SwiftusCore
import Testing

private enum SampleError: Error {
    case boom
}

/// 规格 S2 §3:inject 的激活生命周期、取消、宿主释放、错误回滚、链式收敛。
@ContextTreeActor
@Suite("inject 共效应")
struct InjectTests {
    @Test("依赖齐全激活,消失停用,恢复后在全新子上下文重激活")
    func activationLifecycle() throws {
        let root = Context.root()
        var activated: [String] = []
        var deactivated = 0
        var contexts: [Context] = []
        root.inject(deps: ["logger"]) { child in
            activated.append(child.name)
            contexts.append(child)
            child.onDispose { deactivated += 1 }
        }
        #expect(activated.isEmpty)

        let remove = try root.provide(ServiceKey<Int>("logger"), 1)
        #expect(activated == ["root<logger>"])

        try remove()
        #expect(deactivated == 1)

        try root.provide(ServiceKey<Int>("logger"), 2)
        #expect(activated == ["root<logger>", "root<logger>"])
        #expect(contexts[0] !== contexts[1])
    }

    @Test("宿主释放自动取消注入并撤销活跃子上下文")
    func hostDispose() throws {
        let root = Context.root()
        let host = root.plugin("host") { _ in }
        var deactivated = 0
        host.inject(deps: ["svc"]) { child in
            child.onDispose { deactivated += 1 }
        }
        try root.provide(ServiceKey<Int>("svc"), 1)
        host.dispose()
        #expect(deactivated == 1)
    }

    @Test("取消注入幂等,取消后广播不再激活")
    func cancelIdempotent() throws {
        let root = Context.root()
        var activated = 0
        let cancel = root.inject(deps: ["x"]) { _ in activated += 1 }
        try cancel()
        try cancel()
        try root.provide(ServiceKey<Int>("x"), 1)
        #expect(activated == 0)
    }

    @Test("回调抛错:子上下文回滚并上报兜底通道")
    func callbackError() throws {
        var reported = 0
        let previous = ContextRuntime.uncaughtErrorHandler
        ContextRuntime.uncaughtErrorHandler = { _ in reported += 1 }
        defer { ContextRuntime.uncaughtErrorHandler = previous }

        let root = Context.root()
        var cleaned = 0
        root.inject(deps: ["a"]) { child in
            child.onDispose { cleaned += 1 }
            throw SampleError.boom
        }
        try root.provide(ServiceKey<Int>("a"), 1)
        #expect(cleaned == 1)
        #expect(reported == 1)
    }

    @Test("链式依赖在一次广播内收敛(乱序登记)")
    func chainedConvergence() throws {
        let root = Context.root()
        var order: [String] = []
        root.inject(deps: ["b"]) { _ in order.append("b-ready") }
        root.inject(deps: ["a"]) { _ in
            order.append("a-ready")
            try root.provide(ServiceKey<Int>("b"), 1)
        }
        try root.provide(ServiceKey<Int>("a"), 1)
        #expect(order == ["a-ready", "b-ready"])
    }
}
