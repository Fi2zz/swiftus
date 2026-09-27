import Foundation
import SwiftusCore
import SwiftusFoundation

/// `skill` 工具的默认名；作用域化装配时用 name 换名。
public let kSkillToolName = "skill"

/// 加载技能正文的工具（规格 S14 §7）。
///
/// 只读、无副作用：结果就是一段 `<skill_content>` 文本，由 Agent Loop 正常写进
/// 工具结果，因此「模型可见即已记录」无需额外机制。
@ContextTreeActor
public final class SkillLoadTool: Tool {
    /// 技能来源。
    public let registry: SkillRegistry

    public let name: String

    public init(registry: SkillRegistry, name: String = kSkillToolName) {
        self.registry = registry
        self.name = name
    }

    public var description: String {
        "Load the full instructions for an available skill. Call this with the "
            + "exact skill name from the session skill catalog before acting on a task "
            + "that names or clearly matches that skill."
    }

    public var params: [ParamSpec] {
        [.string(
            "name",
            description: "The exact skill name from the available skills list.",
            required: true
        )]
    }

    public func call(_ context: ToolContext) async throws -> ToolResult {
        let requested = try context.requireString("name").trimmingCharacters(in: .whitespacesAndNewlines)
        if let rejection = rejectionFor(requested) {
            return failure("SKILL_UNAVAILABLE", rejection)
        }
        guard let definition = try await registry.load(requested) else {
            return failure("SKILL_UNKNOWN", "skill \"\(requested)\" is unknown or no longer available")
        }
        return .success(
            renderSkillContent(definition),
            value: .object([
                "name": .string(definition.summary.name),
                "provider": .string(definition.summary.provider),
                "content": .string(definition.content),
            ])
        )
    }

    /// 未命中快照的名字不算拒绝：交给 registry.load 收敛成 SKILL_UNKNOWN。
    private func rejectionFor(_ requested: String) -> String? {
        guard isSkillName(requested) else {
            return "invalid skill name \"\(requested)\""
        }
        guard let summary = findSkillSummary(registry.available, requested) else { return nil }
        return summary.modelInvocable ? nil : "skill \"\(requested)\" is not available for model invocation"
    }

    private func failure(_ code: String, _ message: String) -> ToolResult {
        .failure(skillErrorPayload(code, message), error: ToolError(code, message))
    }

    private func skillErrorPayload(_ code: String, _ message: String) -> String {
        let payload = JSONValue.object(["code": .string(code), "message": .string(message)])
        guard let data = try? payload.jsonData() else { return #"{"code":"error"}"# }
        return String(decoding: data, as: UTF8.self)
    }
}
