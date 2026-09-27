import Foundation

/// 渲染一段技能正文块（`<skill_content>`），模型据此执行指令（规格 S14 §8）。
public func renderSkillContent(_ definition: SkillDefinition) -> String {
    """
    <skill_content name="\(escapeSkillAttribute(definition.summary.name))">
    <skill_resources>
    \(renderSkillResourceHint(definition.resourceBase, provider: definition.summary.provider))
    </skill_resources>

    <skill_instructions>
    \(definition.content)
    </skill_instructions>
    </skill_content>
    """
}

// REASON: 资源基址全形态分派为静态映射表例外（全局 AGENTS.md §6）。
/// 资源基址提示；未声明基址时指向 provider。
public func renderSkillResourceHint(_ base: SkillResourceBase?, provider: String) -> String {
    let tail = "Load referenced resources only as needed."
    switch base {
    case nil:
        return "Resources for this skill are managed by provider \"\(provider)\". \(tail)"
    case let .directory(path):
        return "Base directory for this skill: \(path)\n"
            + "Resolve relative paths mentioned by this skill against the base "
            + "directory before using them. \(tail)"
    case let .url(url):
        return "Base URL for this skill: \(url)\n"
            + "Resolve relative URLs mentioned by this skill against the base URL "
            + "before using them. \(tail)"
    case let .opaque(description):
        return "Resources for this skill: \(description)\n\(tail)"
    }
}

/// 转义出现在属性值里的文本（&、"、<）。
public func escapeSkillAttribute(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "<", with: "&lt;")
}
