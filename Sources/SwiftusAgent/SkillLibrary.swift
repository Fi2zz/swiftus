import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 技能库：轨迹 → 提取 → 注册 → 持久化（规格 S16 §6.5，服务键 'skill'）。
///
/// 同一工具序列出现 threshold 次后用 SkillNamer 命名并构造 SkillTool 注册；
/// 含 high 风险步骤的序列不沉淀；启用前若配了 Approval 需先获批；技能可存进
/// MemoryStore 跨会话恢复。
@ContextTreeActor
public final class SkillLibrary {
    private struct Trace {
        let task: String
        let steps: [SkillStep]
    }

    /// 触发提取的重复次数。
    public let threshold: Int
    /// 命名器（默认由 provideSkillLibrary 用 LLM 装配，缺省确定性命名）。
    public let namer: SkillNamer?
    /// 启用新技能前的审批端口；nil 表示免审批。
    public let approval: (any Approval)?
    /// 技能持久化用的长记忆库；nil 表示不持久化。
    public let memory: MemoryStore?

    private var traces: [Trace] = []
    private var storedSkills: [SkillTool] = []
    private var extracted: Set<String> = []

    /// threshold < 1 快速失败。
    public init(
        threshold: Int = 3,
        namer: SkillNamer? = nil,
        approval: (any Approval)? = nil,
        memory: MemoryStore? = nil
    ) throws {
        guard threshold >= 1 else {
            throw SkillLibraryError.invalidThreshold(threshold)
        }
        self.threshold = threshold
        self.namer = namer
        self.approval = approval
        self.memory = memory
    }

    /// 已沉淀的技能。
    public var skills: [SkillTool] {
        storedSkills
    }

    /// 已记录的轨迹数。
    public var traceCount: Int {
        traces.count
    }

    /// 记录一条成功轨迹。
    public func record(_ task: String, steps: [SkillStep]) {
        guard !steps.isEmpty else { return }
        traces.append(Trace(task: task, steps: steps))
    }

    /// 便捷记录：只有工具名的轨迹。
    public func recordTools(_ task: String, _ tools: [String]) {
        record(task, steps: tools.map { SkillStep(toolName: $0) })
    }

    /// 若某条工具序列达到阈值且可用，提取并注册技能；否则返回 nil。
    public func maybeExtract(tools: ToolRegistry, namer: SkillNamer? = nil) async throws -> SkillTool? {
        guard let trace = firstRepeat() else { return nil }
        let signature = Self.signature(trace.steps)
        extracted.insert(signature)
        guard isSafe(trace.steps, tools: tools) else { return nil }
        let names = trace.steps.map(\.toolName)
        let resolvedNamer = namer ?? self.namer ?? deterministicSkillNamer
        let meta = try await resolvedNamer(trace.task, names)
        let skill = SkillTool(
            name: meta.name,
            description: meta.description,
            steps: trace.steps,
            tools: tools
        )
        if let gate = approval {
            let approved = await gate.request(ApprovalRequest(
                id: "skill-\(Int(Date().timeIntervalSince1970 * 1_000_000))",
                toolName: "skill:\(skill.name)",
                description: skill.description
            ))
            guard approved else { return nil }
        }
        if tools.get(skill.name) == nil {
            try tools.register(skill)
        }
        storedSkills.append(skill)
        try await persist(skill)
        return skill
    }

    /// 把已沉淀技能写入长记忆。
    private func persist(_ skill: SkillTool) async throws {
        guard let memory else { return }
        let data = try skill.jsonValue.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        try await memory.remember(text, tags: ["skill"])
    }

    /// 从长记忆恢复已持久化的技能并注册；返回恢复数量。
    public func restore(tools: ToolRegistry, memory: MemoryStore? = nil) async throws -> Int {
        guard let store = memory ?? self.memory else { return 0 }
        try await store.load()
        var restored = 0
        for entry in store.allEntries where entry.tags.contains("skill") {
            guard let value = try? JSONValue.parse(Data(entry.text.utf8)) else { continue }
            let skill = SkillTool.fromJson(value, tools: tools)
            guard !skill.name.isEmpty, tools.get(skill.name) == nil else { continue }
            try tools.register(skill)
            storedSkills.append(skill)
            restored += 1
        }
        return restored
    }

    private func firstRepeat() -> Trace? {
        var counts: [String: Int] = [:]
        for trace in traces {
            let signature = Self.signature(trace.steps)
            if extracted.contains(signature) { continue }
            let count = (counts[signature] ?? 0) + 1
            counts[signature] = count
            if count >= threshold {
                return trace
            }
        }
        return nil
    }

    /// 安全判定：任一步工具未注册或风险为 high 则不沉淀。
    private func isSafe(_ steps: [SkillStep], tools: ToolRegistry) -> Bool {
        for step in steps {
            guard let tool = tools.get(step.toolName), tool.riskLevel != .high else {
                return false
            }
        }
        return true
    }

    /// 轨迹签名：工具名 `>` 连接。
    static func signature(_ steps: [SkillStep]) -> String {
        steps.map(\.toolName).joined(separator: ">")
    }
}

/// 技能库配置错误。
public enum SkillLibraryError: Error, Equatable {
    /// threshold 非正整数。
    case invalidThreshold(Int)
}

/// 从会话事件里的 tool/result 提取工具名序列（用于技能沉淀）。
public func toolNamesFromEvents(_ events: [SessionEvent]) -> [String] {
    events.compactMap { event in
        guard event.type == SessionEventKind.toolResult, case .object = event.data else { return nil }
        return event.data?["name"]?.stringValue ?? ""
    }
}

/// 'skill' 服务键。
extension ServiceKey where Service == SkillLibrary {
    public static let skill = ServiceKey<SkillLibrary>("skill")
}

/// 提供 'skill' 服务并从长记忆恢复已沉淀技能，返回技能库（规格 S16 §6.5）。
///
/// 命名器优先显式 namer，否则用 llm（或上下文 'llm'）装配 llmSkillNamer，
/// 再否则为确定性命名。审批与记忆缺省取上下文服务。
@ContextTreeActor
@discardableResult
public func provideSkillLibrary(
    _ ctx: Context,
    library: SkillLibrary? = nil,
    llm: (any LlmProvider)? = nil,
    tools: ToolRegistry? = nil,
    memory: MemoryStore? = nil,
    approval: (any Approval)? = nil,
    threshold: Int = 3,
    namer: SkillNamer? = nil
) throws -> SkillLibrary {
    let store = memory ?? ctx.get(.memory)
    let model = llm ?? ctx.get(.llm)
    let resolvedNamer = namer ?? (model.map { llmSkillNamer($0) } ?? deterministicSkillNamer)
    let instance = try library ?? SkillLibrary(
        threshold: threshold,
        namer: resolvedNamer,
        approval: approval ?? ctx.get(.approval),
        memory: store
    )
    try ctx.provide(.skill, instance)
    return instance
}
