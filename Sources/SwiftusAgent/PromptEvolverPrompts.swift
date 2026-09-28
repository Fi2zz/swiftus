import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// prompt-evolver 的 LLM prompt 层（规格 S16 §10.1）：失败模式分析与变体生成。

/// 用 LLM 分析低质量轨迹，提取共性失败模式。
@ContextTreeActor
public func analyzeFailurePatterns(_ llm: any LlmProvider, _ traces: [SessionEvent]) async throws -> String {
    let prompt = """
    以下是 Agent 执行失败的轨迹。请分析共性失败模式：

    \(traces.map(summarizeEvent).joined(separator: "\n"))

    请提取 1-3 个共性失败模式，每个包含：
    1. 模式描述
    2. 典型表现
    3. 可能的 prompt 改进方向
    """
    let result = try await llm.chat(LlmRequest(messages: [
        LlmMessage("system", "你是 Agent 行为分析专家。"),
        LlmMessage("user", prompt),
    ]))
    return result.content
}

/// 基于失败模式生成改进的 prompt 变体。
@ContextTreeActor
public func generateVariant(
    llm: any LlmProvider,
    prompt: SystemPrompt,
    sectionName: String,
    failurePatterns: String,
    parentId: String? = nil
) async throws -> PromptVariant {
    let current = try sectionText(prompt, name: sectionName)
    let generationPrompt = """
    当前 prompt section「\(sectionName)」：
    \(current)

    分析出的失败模式：
    \(failurePatterns)

    请生成一个改进的 prompt 变体，保持原有意图，但解决上述失败模式。
    以 Markdown 格式返回改进后的 section 文本。
    """
    let result = try await llm.chat(LlmRequest(messages: [
        LlmMessage("system", "你是 prompt 工程专家。"),
        LlmMessage("user", generationPrompt),
    ]))
    let now = Date()
    return PromptVariant(
        id: "variant-\(Int(now.timeIntervalSince1970 * 1_000_000))",
        sectionName: sectionName,
        text: result.content,
        reason: failurePatterns,
        createdAt: now,
        parentId: parentId
    )
}

/// 取 prompt 中名为 name 的 section 当前文本；未注册抛错（规格 S16 §10.1）。
@ContextTreeActor
public func sectionText(_ prompt: SystemPrompt, name: String) throws -> String {
    let assembly = prompt.assemble()
    for section in assembly.sections where section.name == name {
        return section.text
    }
    throw PromptEvolverError.sectionNotFound(name)
}

/// 提示词进化错误。
public enum PromptEvolverError: Error, Equatable {
    /// prompt 段未注册。
    case sectionNotFound(String)
    /// 变体不存在。
    case variantNotFound(String)
    /// 依赖的 llm 服务缺失。
    case llmUnavailable
}

/// 把一条事件压缩为单行摘要（类型 + 前 3 个负载字段）。
private func summarizeEvent(_ event: SessionEvent) -> String {
    guard let data = event.data, case let .object(object) = data, !object.isEmpty else {
        return event.type
    }
    let payload = object.prefix(3).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    return "\(event.type)(\(payload))"
}
