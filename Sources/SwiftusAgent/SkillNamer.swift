import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 把任意文本规范为合法工具名（规格 S16 §6.5）。
public func skillNameFrom(_ text: String) -> String {
    let lowered = text.lowercased()
    let sanitized = lowered.replacing(/[^a-z0-9]+/, with: "_")
    let trimmed = sanitized.replacing(/^_+|_+$/, with: "")
    return trimmed.isEmpty ? "skill" : trimmed
}

/// 确定性兜底命名（规格 S16 §6.5）：名由工具序列拼出。
@ContextTreeActor
public func deterministicSkillNamer(_ task: String, _ tools: [String]) async -> SkillMeta {
    SkillMeta(
        name: skillNameFrom("skill_\(tools.joined(separator: "_"))"),
        description: "自动沉淀的技能：依次调用 \(tools.joined(separator: "、"))。"
    )
}

/// 用 LLM 生成技能名与描述，解析失败时回退确定性命名。
@ContextTreeActor
public func llmSkillNamer(_ llm: any LlmProvider, options: [String: JSONValue]? = nil) -> SkillNamer {
    { task, tools in
        let prompt = "任务：\(task)\n成功用到的工具序列：\(tools.joined(separator: " -> "))\n"
            + "请为这个可复用技能取一个 snake_case 英文名并写一句中文描述。"
            + "只回 JSON：{\"name\":\"...\",\"description\":\"...\"}"
        var request = LlmRequest(messages: [LlmMessage("user", prompt)])
        request.options = options
        let result = try await llm.chat(request)
        return try await parseSkillMeta(result.content, tools: tools)
    }
}

/// 从模型文本解析技能元信息，失败时回退确定性命名（规格 S16 §6.5）。
@ContextTreeActor
public func parseSkillMeta(_ text: String, tools: [String]) async throws -> SkillMeta {
    let namePattern = /"name"\s*:\s*"([^"]+)"/.ignoresCase()
    let descPattern = /"description"\s*:\s*"([^"]*)"/.ignoresCase()
    guard let nameMatch = text.firstMatch(of: namePattern) else {
        return await deterministicSkillNamer("", tools)
    }
    let name = skillNameFrom(String(nameMatch.output.1))
    if let descMatch = text.firstMatch(of: descPattern) {
        return SkillMeta(name: name, description: String(descMatch.output.1))
    }
    return SkillMeta(name: name, description: "自动沉淀的技能：\(tools.joined(separator: "、"))。")
}
