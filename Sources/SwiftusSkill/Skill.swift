import SwiftusCore
import SwiftusFoundation

/// `ctx.skillRegistry`：当前上下文可见的技能注册表。
///
/// 与 conatus_agent 的「技能沉淀库」不是同一件事：这里是「按需加载一段指令」，
/// 那边是「把重复的工具序列沉淀成新工具」。
extension Context {
    public var skillRegistry: SkillRegistry {
        get throws { try require(.skillRegistry) }
    }
}

/// 'skillRegistry' 服务键。
extension ServiceKey where Service == SkillRegistry {
    public static let skillRegistry = ServiceKey<SkillRegistry>("skillRegistry")
}

/// 提供服务键 'skillRegistry'，注册 providers 与 inlineSkills 并完成首次收集（规格 S14 §9）。
///
/// inlineSkills 是「直接把一段提示词当技能用」的入口：不落盘、不解析 frontmatter，
/// 只要求 kebab-case 名字与非空描述。注册表的生命周期随 ctx。
@ContextTreeActor
@discardableResult
public func provideSkillRegistry(
    _ ctx: Context,
    providers: [any SkillProvider] = [],
    inlineSkills: [SkillRegistration] = [],
    registry: SkillRegistry? = nil
) async throws -> SkillRegistry {
    let resolved = registry ?? SkillRegistry()
    try ctx.provide(.skillRegistry, resolved)
    ctx.onDispose { resolved.dispose() }
    for provider in providers {
        try ctx.effect { try resolved.registerProvider(provider) }
    }
    for registration in inlineSkills {
        try ctx.effect { try resolved.register(registration) }
    }
    await resolved.refresh()
    return resolved
}

/// 把技能目录挂成一段 system prompt；目录为空时不注册任何段（规格 S14 §9）。
@ContextTreeActor
@discardableResult
public func provideSkillCatalog(
    _ ctx: Context,
    order: Int = kSkillCatalogSectionOrder
) throws -> SkillCatalogSection {
    let section = SkillCatalogSection(
        registry: try ctx.require(.skillRegistry),
        prompt: try ctx.require(.systemPrompt),
        order: order
    )
    ctx.effect { section.attach() }
    return section
}

/// 注册 `skill` 工具（规格 S14 §9）；tools 缺省用 `ctx.tools`。
@ContextTreeActor
@discardableResult
public func provideSkillTool(
    _ ctx: Context,
    tools: ToolRegistry? = nil,
    name: String = kSkillToolName
) throws -> SkillLoadTool {
    let tool = SkillLoadTool(registry: try ctx.require(.skillRegistry), name: name)
    let registry = try tools ?? ctx.tools
    try ctx.effect { try registry.register(tool) }
    return tool
}

/// 注册目录发现型 provider 并完成一次收集（规格 S14 §9）。
/// 目录监听本版不实现：watch 保留但不生效，技能变更以手动 refresh() 代替（S14 注记）。
@ContextTreeActor
@discardableResult
public func provideSkillFilesystem(
    _ ctx: Context,
    roots: [SkillRoot]? = nil,
    watch: Bool = false
) async throws -> SkillFilesystemProvider {
    let registry = try ctx.require(.skillRegistry)
    let provider = SkillFilesystemProvider(
        roots: roots ?? defaultSkillRoots(),
        onWarning: registry.onWarning
    )
    try ctx.effect { try registry.registerProvider(provider) }
    if watch {
        registry.reportWarning("目录监听暂未实现（W1）：技能变更需手动 refresh()")
    }
    await registry.refresh()
    return provider
}
