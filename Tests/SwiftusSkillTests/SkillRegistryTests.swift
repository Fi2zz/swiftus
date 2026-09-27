import Foundation
import SwiftusCore
import SwiftusSkill
import Testing

/// 规格 S14 §4:注册表注册校验、快照、onChange、load 与作用域级联。
@ContextTreeActor
@Suite("SkillRegistry 注册表")
struct SkillRegistryTests {
    @Test("registerProvider:非法名与重复名抛错;撤销后重新收集")
    func providerRegistration() async throws {
        let registry = SkillRegistry()
        #expect(throws: SkillRegistryError.invalidName("BAD NAME")) {
            try registry.registerProvider(FakeSkillProvider(name: "BAD NAME"))
        }
        let disposer = try registry.registerProvider(FakeSkillProvider(name: "fake", candidates: [
            SkillCandidate(summary: makeSummary("one")),
        ]))
        #expect(throws: SkillRegistryError.duplicateProvider("fake")) {
            try registry.registerProvider(FakeSkillProvider(name: "fake"))
        }
        await registry.refresh()
        #expect(registry.available.map(\.name) == ["one"])
        try disposer()
        await registry.refresh()
        #expect(registry.available.isEmpty)
    }

    @Test("register 运行时技能:校验与快照;modelInvocable 过滤")
    func runtimeRegistration() async throws {
        let registry = SkillRegistry()
        #expect(throws: SkillRegistryError.emptyDescription) {
            try registry.register(SkillRegistration(name: "a-b", description: "  "))
        }
        #expect(throws: SkillRegistryError.invalidName("A_B")) {
            try registry.register(SkillRegistration(name: "A_B", description: "x"))
        }
        try registry.register(SkillRegistration(name: "beta", description: "二"))
        try registry.register(SkillRegistration(name: "alpha", description: "一"))
        #expect(throws: SkillRegistryError.duplicateRuntime("alpha")) {
            try registry.register(SkillRegistration(name: "alpha", description: "重"))
        }
        await registry.refresh()
        #expect(registry.available.map(\.name) == ["alpha", "beta"])
        #expect(registry.modelInvocable.map(\.name) == ["alpha", "beta"])
    }

    @Test("onChange:快照确有变化才通知")
    func changeNotification() async throws {
        let registry = SkillRegistry()
        let provider = FakeSkillProvider(name: "fake", candidates: [
            SkillCandidate(summary: makeSummary("one")),
        ])
        try registry.registerProvider(provider)
        var changes = 0
        registry.onChange { changes += 1 }
        await registry.refresh()
        #expect(changes == 1)
        await registry.refresh()
        #expect(changes == 1)
        provider.candidates = [SkillCandidate(summary: makeSummary("one")), SkillCandidate(summary: makeSummary("two"))]
        await registry.refresh()
        #expect(changes == 2)
    }

    @Test("invalidate:合并窗口内多次失效只收集一次")
    func invalidateCoalescing() async throws {
        let registry = SkillRegistry(refreshDebounce: 0.05)
        let provider = FakeSkillProvider(name: "fake")
        try registry.registerProvider(provider)
        await registry.refresh()
        let baseline = provider.listCalls
        registry.invalidate()
        registry.invalidate()
        registry.invalidate()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(provider.listCalls == baseline + 1)
    }

    @Test("load:未知名、运行时技能、provider 技能与 provider 消失")
    func loadPaths() async throws {
        let registry = SkillRegistry()
        let provider = FakeSkillProvider(name: "fake", candidates: [
            SkillCandidate(summary: makeSummary("from-file", provider: "fake")),
        ])
        provider.definitions["from-file"] = SkillDefinition(
            summary: makeSummary("from-file", provider: "fake"),
            content: "文件正文"
        )
        try registry.registerProvider(provider)
        try registry.register(SkillRegistration(name: "inline", description: "x", content: "内联正文"))
        await registry.refresh()

        #expect(try await registry.load("unknown") == nil)
        #expect(try await registry.load("not a name") == nil)
        #expect(try await registry.load("inline")?.content == "内联正文")
        #expect(try await registry.load("from-file")?.content == "文件正文")

        provider.definitions.removeAll()
        #expect(try await registry.load("from-file") == nil)
    }

    @Test("父子作用域:同名子级赢;父级变化级联但不重跑子级 provider")
    func parentChild() async throws {
        let parent = SkillRegistry()
        try parent.register(SkillRegistration(name: "shared", description: "父版"))
        try parent.register(SkillRegistration(name: "from-parent", description: "父"))
        await parent.refresh()

        let childProvider = FakeSkillProvider(name: "child-p")
        let child = SkillRegistry(parent: parent)
        try child.registerProvider(childProvider)
        try child.register(SkillRegistration(name: "shared", description: "子版"))
        await child.refresh()

        #expect(child.available.map(\.name) == ["from-parent", "shared"])
        #expect(child.available.first { $0.name == "shared" }?.description == "子版")
        #expect(try await child.load("from-parent")?.summary.description == "父")
        #expect(try await child.load("shared")?.summary.description == "子版")

        let callsBefore = childProvider.listCalls
        try parent.register(SkillRegistration(name: "late", description: "晚到"))
        await parent.refresh()
        #expect(child.available.map(\.name) == ["from-parent", "late", "shared"])
        #expect(childProvider.listCalls == callsBefore)
    }

    @Test("dispose:清空快照与监听,幂等")
    func dispose() async throws {
        let registry = SkillRegistry()
        try registry.register(SkillRegistration(name: "a-b", description: "x"))
        await registry.refresh()
        #expect(!registry.available.isEmpty)
        registry.dispose()
        registry.dispose()
        #expect(registry.available.isEmpty)
        #expect(registry.disposed)
        #expect(throws: SkillRegistryError.registryDisposed) {
            try registry.register(SkillRegistration(name: "c-d", description: "x"))
        }
    }
}
