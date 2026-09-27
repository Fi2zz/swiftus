import Foundation
import SwiftusCore

/// 注册表错误（消息原文与 Dart 对齐）。
public enum SkillRegistryError: Error, Equatable {
    /// provider / 技能名不是 kebab-case。
    case invalidName(String)
    /// 运行时技能 description 为空。
    case emptyDescription
    /// provider 重复注册：`技能 provider "name" 已注册。`
    case duplicateProvider(String)
    /// 运行时技能重复注册：`运行时技能 "name" 已注册。`
    case duplicateRuntime(String)
    /// 已释放注册表再注册：`技能注册表已释放，无法再注册。`
    case registryDisposed
}

/// 技能注册表：provider 与运行时技能的集散地，维护一份可同步读取的可用快照（规格 S14 §4）。
///
/// available 是目录渲染与工具过滤读取的同步快照；provider 产出、运行时注册与
/// invalidate 都只标脏并调度一次收集，完成后若快照确有变化，经 onChange 通知。
/// 传入 parent 时本注册表成为子作用域：父级快照经 visible 过滤后并入，同名由本
/// 注册表赢下；父级变化级联到这里，只重新合并不重跑本注册表的 provider。
@ContextTreeActor
public final class SkillRegistry {
    /// provider 侧的降级上报（不会中断收集）。
    public let onWarning: (@ContextTreeActor (String) -> Void)?

    private let _parent: SkillRegistry?
    private let visible: SkillVisibility?
    private var providers: [any SkillProvider] = []
    private var runtime: [String: SkillRegistration] = [:]
    private var runtimeOrder: [String] = []
    private var listeners: [(token: Int, body: @ContextTreeActor () -> Void)] = []
    private var nextToken = 0
    private var collector: SkillCollector!
    private var parentSubscription: Int?
    private var own: [SkillSummary] = []
    private var _disposed = false

    /// 当前可用技能的同步快照（名字码位升序），含继承自父级的部分。
    public private(set) var available: [SkillSummary] = []

    public init(
        refreshDebounce: TimeInterval = 0.05,
        onWarning: (@ContextTreeActor (String) -> Void)? = nil,
        parent: SkillRegistry? = nil,
        visible: SkillVisibility? = nil
    ) {
        self.onWarning = onWarning
        self._parent = parent
        self.visible = visible
        // 两阶段初始化:hooks 闭包弱引用 self,collector 须在其余属性就位后装配。
        collector = SkillCollector(
            debounce: refreshDebounce,
            hooks: CollectorHooks(
                providers: { [weak self] in self?.providers ?? [] },
                runtime: { [weak self] in self?.runtimeList() ?? [] },
                publish: { [weak self] in self?.publish($0) },
                onWarning: onWarning
            )
        )
        parentSubscription = parent?.onChange { [weak self] in self?.republish() }
    }

    /// 父作用域；根注册表为 nil。
    public var parent: SkillRegistry? {
        _parent
    }

    /// 从父级继承技能的过滤谓词；nil 表示全部继承。
    public var visibility: SkillVisibility? {
        visible
    }

    /// 本注册表自己注册的 provider（不含父级）。
    public var providerList: [any SkillProvider] {
        providers
    }

    /// 快照里允许模型调用的技能。
    public var modelInvocable: [SkillSummary] {
        available.filter(\.modelInvocable)
    }

    /// 注册表是否已释放。
    public var disposed: Bool {
        _disposed
    }

    /// 上报一条降级消息（onWarning 的便捷出口）。
    public func reportWarning(_ message: String) {
        onWarning?(message)
    }

    /// 注册一个 provider；返回撤销函数（幂等），撤销后重新收集。
    @discardableResult
    public func registerProvider(_ provider: any SkillProvider) throws -> Disposer {
        try ensureActive()
        guard isSkillName(provider.name) else {
            throw SkillRegistryError.invalidName(provider.name)
        }
        guard !providers.contains(where: { $0.name == provider.name }) else {
            throw SkillRegistryError.duplicateProvider(provider.name)
        }
        providers.append(provider)
        invalidate()
        var removed = false
        return { [weak self] in
            guard let self, !removed else { return }
            removed = true
            guard let index = self.providers.firstIndex(where: { $0.name == provider.name }) else { return }
            self.providers.remove(at: index)
            self.invalidate()
        }
    }

    /// 注册一条运行时技能；返回撤销函数（幂等），撤销后重新收集。
    @discardableResult
    public func register(_ registration: SkillRegistration) throws -> Disposer {
        try ensureActive()
        guard isSkillName(registration.name) else {
            throw SkillRegistryError.invalidName(registration.name)
        }
        guard !registration.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillRegistryError.emptyDescription
        }
        guard runtime[registration.name] == nil else {
            throw SkillRegistryError.duplicateRuntime(registration.name)
        }
        runtime[registration.name] = registration
        runtimeOrder.append(registration.name)
        invalidate()
        var removed = false
        return { [weak self] in
            guard let self, !removed else { return }
            removed = true
            guard self.runtime.removeValue(forKey: registration.name) != nil else { return }
            self.runtimeOrder.removeAll { $0 == registration.name }
            self.invalidate()
        }
    }

    /// 监听快照变化（逐字段相同的重复收集不通知），返回注销令牌。
    @discardableResult
    public func onChange(_ body: @escaping @ContextTreeActor () -> Void) -> Int {
        nextToken += 1
        listeners.append((token: nextToken, body: body))
        return nextToken
    }

    /// 注销一个变化监听，返回是否确实移除。
    @discardableResult
    public func removeChangeListener(_ token: Int) -> Bool {
        guard let index = listeners.firstIndex(where: { $0.token == token }) else { return false }
        listeners.remove(at: index)
        return true
    }

    /// 立即重新收集所有技能。
    public func refresh() async {
        await collector.refresh()
    }

    /// 标记快照已过期并调度一次收集。
    public func invalidate() {
        collector.invalidate()
    }

    /// 按名字加载完整定义；只认当前可见集合——被过滤、未知或已消失的都返回空，
    /// 因此模型无法绕过目录调用一个不可见的技能（规格 S14 §4）。
    public func load(_ name: String) async throws -> SkillDefinition? {
        guard isSkillName(name) else { return nil }
        guard let summary = findSkillSummary(available, name) else { return nil }
        guard findSkillSummary(own, name) != nil else { return try await _parent?.load(name) }
        if let registration = runtime[name] { return registration.definition }
        guard let provider = providerNamed(providers, summary.provider) else { return nil }
        return try await loadFrom(provider, summary)
    }

    /// 释放注册表：取消待执行的收集、父级级联与全部监听。幂等。
    public func dispose() {
        guard !_disposed else { return }
        _disposed = true
        if let token = parentSubscription { _parent?.removeChangeListener(token) }
        parentSubscription = nil
        collector.dispose()
        providers.removeAll()
        runtime.removeAll()
        runtimeOrder.removeAll()
        listeners.removeAll()
        own = []
        available = []
    }

    private func runtimeList() -> [SkillRegistration] {
        runtimeOrder.compactMap { runtime[$0] }
    }

    private func publish(_ collected: [SkillSummary]) {
        guard !_disposed else { return }
        own = collected
        republish()
    }

    /// 用当前自身快照与父级快照重新合并并发布；父级变化也走这里。
    private func republish() {
        guard !_disposed else { return }
        let merged = mergeScopedSummaries(
            parent: _parent?.available ?? [],
            own: own,
            visible: visible,
            onShadowed: onWarning
        )
        guard !sameSkillSnapshot(merged, available) else { return }
        available = merged
        for entry in listeners {
            entry.body()
        }
    }

    private func loadFrom(_ provider: any SkillProvider, _ summary: SkillSummary) async throws -> SkillDefinition? {
        guard let definition = try await provider.load(summary) else {
            invalidate()
            return nil
        }
        return definition
    }

    private func ensureActive() throws {
        guard !_disposed else {
            throw SkillRegistryError.registryDisposed
        }
    }
}
