import SwiftusCore

/// prompt 段与动态上下文的注册表 + 装配 / 渲染（规格 S6）。
///
/// 各插件在各自的上下文里注册段或上下文（返回 Disposer，随插件卸载自动撤销），
/// assemble() 按 order 升序求值，render() / renderContexts() 分别拼接段与
/// 动态上下文，并做 {{variable}} 插值。
@ContextTreeActor
public final class SystemPrompt {
    private var sections: [PromptSection] = []
    private var contexts: [PromptContext] = []

    /// 自动生成段名的序号（只增不减，remove 后不复用）。
    private var addSeq = 0

    public init() {}

    /// 已注册的 prompt 段（注册顺序）。
    public var sectionList: [PromptSection] {
        sections
    }

    /// 已注册的动态上下文（注册顺序）。
    public var contextList: [PromptContext] {
        contexts
    }

    /// 注册一段 prompt；同名重复注册抛 SystemPromptError.duplicateSection，返回幂等 Disposer。
    @discardableResult
    public func section(_ section: PromptSection) throws -> Disposer {
        guard !sections.contains(where: { $0.name == section.name }) else {
            throw SystemPromptError.duplicateSection(section.name)
        }
        sections.append(section)
        var removed = false
        return { [weak self] in
            guard let self, !removed else { return }
            removed = true
            _ = self.remove(section.name)
        }
    }

    /// 用一段纯文本创建并注册 prompt 段；name 缺省时自动生成唯一名（add-N）。
    /// 返回该段句柄（含自动名），供 remove 使用。
    @discardableResult
    public func add(_ prompt: String, name: String? = nil) throws -> PromptSection {
        let created = PromptSection(name: name ?? nextAddName(), text: { prompt })
        _ = try section(created)
        return created
    }

    /// 注册一份动态上下文；同名重复注册抛 SystemPromptError.duplicateContext，返回幂等 Disposer。
    @discardableResult
    public func context(_ context: PromptContext) throws -> Disposer {
        guard !contexts.contains(where: { $0.name == context.name }) else {
            throw SystemPromptError.duplicateContext(context.name)
        }
        contexts.append(context)
        var removed = false
        return { [weak self] in
            guard let self, !removed else { return }
            removed = true
            _ = self.remove(context.name)
        }
    }

    /// 移除一段已注册的段或上下文；未注册时返回 false（幂等）。
    @discardableResult
    public func remove(_ name: String) -> Bool {
        if let index = sections.firstIndex(where: { $0.name == name }) {
            sections.remove(at: index)
            return true
        }
        guard let index = contexts.firstIndex(where: { $0.name == name }) else { return false }
        contexts.remove(at: index)
        return true
    }

    /// 装配：段与上下文分别按 order 升序、同序按 name 排序，逐条求值（规格 S6 §3）。
    public func assemble(variables: [String: String] = [:]) -> PromptAssembly {
        PromptAssembly(
            sections: ordered(sections).map { AssembledSection(name: $0.name, text: $0.text()) },
            contexts: ordered(contexts).map { AssembledContext(name: $0.name, text: $0.text()) },
            variables: variables
        )
    }

    /// 渲染 prompt 段为一段文本并插值；不过滤空文本（规格 S6 §4）。
    public func render(_ assembly: PromptAssembly, separator: String = "\n\n") -> String {
        assembly.sections
            .map { Self.interpolate($0.text, variables: assembly.variables) }
            .joined(separator: separator)
    }

    /// 渲染动态上下文并插值；空文本不贡献内容。
    public func renderContexts(_ assembly: PromptAssembly, separator: String = "\n\n") -> String {
        assembly.contexts
            .map { Self.interpolate($0.text, variables: assembly.variables) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    /// 把 {{name}} 替换为 variables 中的值；未知占位符原样保留。
    public static func interpolate(_ text: String, variables: [String: String]) -> String {
        text.replacing(/\{\{([A-Za-z0-9_]+)\}\}/) { match in
            variables[String(match.output.1)] ?? String(match.output.0)
        }
    }

    /// 生成未占用的 add-N 名：单调递增、remove 后不复用。
    private func nextAddName() -> String {
        var candidate: String
        repeat {
            candidate = "add-\(addSeq)"
            addSeq += 1
        } while sections.contains(where: { $0.name == candidate })
        return candidate
    }

    private func ordered<T: PromptEntry>(_ entries: [T]) -> [T] {
        entries.sorted { lhs, rhs in
            guard lhs.order == rhs.order else { return lhs.order < rhs.order }
            return lhs.name < rhs.name
        }
    }
}

/// `ctx.systemPrompt`：当前上下文可见的 prompt 注册表（未提供时抛错）。
extension Context {
    public var systemPrompt: SystemPrompt {
        get throws { try require(.systemPrompt) }
    }
}

/// 'systemPrompt' 服务键。
extension ServiceKey where Service == SystemPrompt {
    public static let systemPrompt = ServiceKey<SystemPrompt>("systemPrompt")
}

/// 将 SystemPrompt 作为 'systemPrompt' 服务提供到上下文（规格 S6 §5）。
@ContextTreeActor
@discardableResult
public func provideSystemPrompt(_ ctx: Context, prompt: SystemPrompt? = nil) throws -> SystemPrompt {
    let resolved = prompt ?? SystemPrompt()
    try ctx.provide(.systemPrompt, resolved)
    return resolved
}
