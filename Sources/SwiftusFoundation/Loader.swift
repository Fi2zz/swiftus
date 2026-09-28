import Foundation
import SwiftusCore

/// 插件工厂：接收子上下文与配置，在子上下文上施加副作用（规格 S19 §5）。
///
/// 配置取 `JSONValue?`（与全项目「动态 JSON 走 JSONValue」的纪律一致）。
public typealias PluginFactory = @ContextTreeActor (Context, JSONValue?) throws -> Void

/// loader 错误（规格 S19 §5）。
public struct LoaderException: Error, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

extension LoaderException: CustomStringConvertible {
    public var description: String {
        "LoaderException: \(message)"
    }
}

/// loader 配置树的一个节点（规格 S19 §5）。
///
/// `name` 为 nil 时是**分组节点**，本身不加载插件，只承载 `children`。
public struct LoaderEntry: Sendable, Equatable {
    /// 稳定 id；缺省时由 `Loader` 自动生成。
    public let id: String?
    /// 插件名（注册表键）；nil 表示分组。
    public let name: String?
    /// 传给插件工厂的配置。
    public let config: JSONValue?
    /// 禁用该 entry（分组不受影响）。
    public let disabled: Bool
    public let children: [LoaderEntry]

    public init(
        id: String? = nil,
        name: String? = nil,
        config: JSONValue? = nil,
        disabled: Bool = false,
        children: [LoaderEntry] = []
    ) {
        self.id = id
        self.name = name
        self.config = config
        self.disabled = disabled
        self.children = children
    }

    /// 是否是分组节点。
    public var isGroup: Bool {
        name == nil
    }

    /// 序列化为 JSON（**缺省字段不出现**：id / name / config 为空、`disabled` 为假、
    /// 子节点为空时都不输出——与 Dart 的 `toJson` 同形）。
    public var json: JSONValue {
        var object: [String: JSONValue] = [:]
        if let id { object["id"] = .string(id) }
        if let name { object["name"] = .string(name) }
        if let config { object["config"] = config }
        if disabled { object["disabled"] = .bool(true) }
        if !children.isEmpty { object["children"] = .array(children.map(\.json)) }
        return .object(object)
    }

    /// 从 JSON 反序列化。
    ///
    /// 缺省字段：id / name / config 为空、`disabled` 缺省假、`children` 缺省空列表。
    public static func from(_ json: JSONValue) throws -> LoaderEntry {
        let object = json.objectValue ?? [:]
        var children: [LoaderEntry] = []
        for child in object["children"]?.arrayValue ?? [] {
            children.append(try from(child))
        }
        return LoaderEntry(
            id: object["id"]?.stringValue,
            name: object["name"]?.stringValue,
            config: object["config"].flatMap { $0 == .null ? nil : $0 },
            disabled: object["disabled"] == .bool(true),
            children: children
        )
    }
}

/// 装载器服务：持有插件注册表与已加载的 entry 树（规格 S19 §5，服务键 `loader`）。
///
/// 已加载的 entry 都是**装载器上下文的子上下文**，随宿主上下文释放而自动卸载。
@ContextTreeActor
public final class Loader {
    private let host: Context
    private var factories: [String: PluginFactory] = [:]
    private var factoryOrder: [String] = []
    private var entries: [String: LoaderEntry] = [:]
    private var entryOrder: [String] = []
    private var running: [String: Context] = [:]
    private var seq = 0

    public init(_ host: Context, plugins: [String: PluginFactory] = [:]) {
        self.host = host
        for (name, factory) in plugins {
            factories[name] = factory
            factoryOrder.append(name)
        }
    }

    // MARK: - 注册表

    /// 注册一个插件工厂；同名会覆盖。
    public func register(_ name: String, _ factory: @escaping PluginFactory) throws {
        guard !name.isEmpty else {
            throw LoaderException("插件名不能为空")
        }
        if factories[name] == nil {
            factoryOrder.append(name)
        }
        factories[name] = factory
    }

    /// 注销一个插件工厂；返回是否确实移除了一个。
    @discardableResult
    public func unregister(_ name: String) -> Bool {
        guard factories.removeValue(forKey: name) != nil else { return false }
        factoryOrder.removeAll { $0 == name }
        return true
    }

    /// 是否已注册某插件。
    public func has(_ name: String) -> Bool {
        factories[name] != nil
    }

    /// 已注册的插件名（注册顺序）。
    public var names: [String] {
        factoryOrder.filter { factories[$0] != nil }
    }

    // MARK: - 配置树

    /// 已加载 entry 的 id（**加载顺序**）。
    public var ids: [String] {
        entryOrder
    }

    /// 是否没有任何 entry。
    public var isEmpty: Bool {
        entries.isEmpty
    }

    /// entry 对应的插件子上下文；未加载或未运行时为 nil。
    public func contextOf(_ id: String) -> Context? {
        running[id]
    }

    /// entry 的配置节点。
    public func entryOf(_ id: String) -> LoaderEntry? {
        entries[id]
    }

    /// 全量替换配置树：先卸载现有 entry（逆序），再按 `entries` 重新加载。
    public func apply(_ entries: [LoaderEntry]) throws {
        for id in entryOrder.reversed() {
            running.removeValue(forKey: id)?.dispose()
        }
        self.entries.removeAll()
        entryOrder.removeAll()
        for entry in entries {
            _ = try load(entry)
        }
    }

    /// 从 JSON 配置全量替换配置树。
    public func applyJson(_ entries: [JSONValue]) throws {
        try apply(try entries.map(LoaderEntry.from))
    }

    /// 加载一个 entry，返回其 id；分组会递归加载 `children`。
    @discardableResult
    public func load(_ entry: LoaderEntry, parent: String? = nil) throws -> String {
        let id = entry.id ?? nextId(parent: parent)
        guard entries[id] == nil else {
            throw LoaderException("entry \"\(id)\" 已存在")
        }
        entries[id] = entry
        entryOrder.append(id)

        if !entry.isGroup, !entry.disabled {
            guard let factory = factories[entry.name ?? ""] else {
                // 失败不留残迹：先摘掉刚登记的 id。
                entries.removeValue(forKey: id)
                entryOrder.removeAll { $0 == id }
                throw LoaderException("未注册的插件 \"\(entry.name ?? "")\"（entry \"\(id)\"）")
            }
            running[id] = try host.plugin(id) { child in
                try factory(child, entry.config)
            }
        }

        for child in entry.children {
            _ = try load(child, parent: id)
        }
        return id
    }

    /// 卸载 entry 及其所有后代（按 `id` 或 `id:` 前缀匹配，逆序卸载）。
    public func remove(_ id: String) throws {
        let targets = entryOrder
            .filter { $0 == id || $0.hasPrefix("\(id):") }
            .reversed()
        guard !targets.isEmpty else {
            throw LoaderException("未知 entry \"\(id)\"")
        }
        for key in targets {
            running.removeValue(forKey: key)?.dispose()
            entries.removeValue(forKey: key)
            entryOrder.removeAll { $0 == key }
        }
    }

    /// 重启单个 entry 的插件（分组与禁用项不重启）。
    public func reload(_ id: String) throws {
        guard let entry = entries[id] else {
            throw LoaderException("未知 entry \"\(id)\"")
        }
        running.removeValue(forKey: id)?.dispose()
        guard !entry.isGroup, !entry.disabled else { return }
        guard let factory = factories[entry.name ?? ""] else {
            throw LoaderException("未注册的插件 \"\(entry.name ?? "")\"（entry \"\(id)\"）")
        }
        running[id] = try host.plugin(id) { child in
            try factory(child, entry.config)
        }
    }

    /// id 生成：全局自增的 `entry-<序号>`，有父时加 `<父id>:` 前缀（规格 S19 §5）。
    private func nextId(parent: String?) -> String {
        seq += 1
        let id = "entry-\(seq)"
        return parent.map { "\($0):\(id)" } ?? id
    }
}

extension ServiceKey where Service == Loader {
    public static let loader = ServiceKey<Loader>("loader")
}

/// 将 `Loader` 提供到上下文，可选预注册插件并立即加载 `config`（规格 S19 §5）。
@ContextTreeActor
@discardableResult
public func provideLoader(
    _ ctx: Context,
    plugins: [String: PluginFactory] = [:],
    config: [LoaderEntry]? = nil
) throws -> Loader {
    let loader = Loader(ctx, plugins: plugins)
    try ctx.provide(.loader, loader)
    if let config {
        try loader.apply(config)
    }
    return loader
}
