import SwiftusCore
import Testing

/// 规格 S2 §2 / §5:服务可见性、provide 守卫、nil 值语义、级联释放。
@ContextTreeActor
@Suite("Context 服务树")
struct ContextServicesTests {
    @Test("服务沿父链向下可见,父不可见子服务")
    func visibility() throws {
        let root = Context.root()
        try root.provide(ServiceKey<Int>("answer"), 42)
        let child = root.plugin("sub") { _ in }
        #expect(child.name == "Context(root)/sub")
        #expect(child.get(ServiceKey<Int>("answer")) == 42)
        try child.provide(ServiceKey<String>("own"), "x")
        #expect(root.get(ServiceKey<String>("own")) == nil)
        #expect(child.contains("own"))
        #expect(!root.contains("own"))
        #expect(child.localServiceKeys == ["own"])
    }

    @Test("require 缺服务抛 serviceUnavailable")
    func requireMissing() {
        let root = Context.root(name: "app")
        #expect(throws: ContextError.serviceUnavailable(key: "logger", context: "app")) {
            _ = try root.require(ServiceKey<Int>("logger"))
        }
    }

    @Test("重复提供与释放后提供均抛错")
    func provideGuards() throws {
        let root = Context.root()
        try root.provide(ServiceKey<Int>("k"), 1)
        #expect(throws: ContextError.duplicateService(key: "k", context: "root")) {
            try root.provide(ServiceKey<Int>("k"), 2)
        }
        root.dispose()
        #expect(throws: ContextError.contextDisposed(key: "k2", context: "root")) {
            try root.provide(ServiceKey<Int>("k2"), 2)
        }
    }

    @Test("提供 nil 值:contains 为真、get 为 nil、require 抛错")
    func nilValue() throws {
        let root = Context.root()
        try root.provide(ServiceKey<Int>("maybe"), nil)
        #expect(root.contains("maybe"))
        #expect(root.get(ServiceKey<Int>("maybe")) == nil)
        #expect(throws: ContextError.serviceUnavailable(key: "maybe", context: "root")) {
            _ = try root.require(ServiceKey<Int>("maybe"))
        }
    }

    @Test("provide 的 Disposer 幂等且不误删新值")
    func disposerIdempotent() throws {
        let root = Context.root()
        let first = try root.provide(ServiceKey<String>("k"), "v1")
        try first()
        #expect(root.get(ServiceKey<String>("k")) == nil)
        try root.provide(ServiceKey<String>("k"), "v2")
        try first()
        #expect(root.get(ServiceKey<String>("k")) == "v2")
    }

    @Test("dispose 级联释放子树且幂等")
    func cascadeDispose() throws {
        let root = Context.root()
        var cleaned = 0
        let child = root.plugin("p") { context in
            context.onDispose { cleaned += 1 }
        }
        root.dispose()
        root.dispose()
        #expect(cleaned == 1)
        #expect(child.disposed)
        #expect(root.disposed)
    }
}
