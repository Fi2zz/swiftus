import Foundation

/// 目录的引导句。
public let kSkillCatalogIntro = "A skill is a reusable set of task-specific instructions. "
    + "The following skills are available in this session:"

/// 目录的收尾指令（本版只做模型侧调用，故不涉及用户直接调用）。
public let kSkillCatalogInstruction = "If the user names a skill, or the task clearly matches a skill's "
    + "description, call the `skill` tool with the exact skill name before "
    + "taking task actions. Load all applicable skills, then follow their full "
    + "instructions. This catalog contains summaries only; do not infer or "
    + "follow a skill's instructions until it has been loaded."

/// description 在目录里的默认长度上限。
public let kSkillCatalogDescriptionMaxLength = 500

/// 渲染技能目录；skills 必须非空（空目录不产生任何段，规格 S14 §6）。
public func renderSkillCatalog(
    _ skills: [SkillSummary],
    descriptionMaxLength: Int = kSkillCatalogDescriptionMaxLength
) -> String {
    var buffer = "<system-reminder>\n\(kSkillCatalogIntro)\n\n<available_skills>\n"
    for skill in skills {
        let description = normalizeSkillDescription(skill.description, maxLength: descriptionMaxLength)
        buffer += "- `\(skill.name)`: \(escapeSkillText(description))\n"
    }
    buffer += "</available_skills>\n\n\(kSkillCatalogInstruction)\n</system-reminder>"
    return buffer
}

/// 折叠空白并截断到 maxLength（截断时以 ... 结尾）。
public func normalizeSkillDescription(_ description: String, maxLength: Int) -> String {
    let collapsed = description
        .replacing(/\s+/, with: " ")
        .trimmingCharacters(in: .whitespaces)
    guard collapsed.count > maxLength else { return collapsed }
    return "\(collapsed.prefix(maxLength - 3))..."
}

/// 转义目录里的文本内容（&、<、>）。
public func escapeSkillText(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
