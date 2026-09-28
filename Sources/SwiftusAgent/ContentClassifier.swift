import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 模型消息的内容类别（规格 S16 §6.4）。
public enum MessageCategory: String, Sendable, CaseIterable {
    /// system 中的人设与指令部分（稳定前缀）。
    case systemPrompt
    /// system 中的工具说明部分（稳定前缀）。
    case toolDefinition
    /// system 中的技能清单部分（稳定前缀）。
    case skillList
    /// 工具结果：可由日志或工具重放重建，压成摘要 + 指针。
    case toolResult
    /// 用户偏好表达：跨轮生效，原文保留。
    case userPreference
    /// 用户任务描述：当前目标，原文保留。
    case userTask
    /// 早期对话：折叠进滚动摘要。
    case earlyConversation
    /// 近期对话：留给滑动窗口。
    case recentConversation
}

/// 类别对应的压缩策略。
public enum CompressionStrategy: String, Sendable {
    /// 原样保留（稳定前缀，任何压缩都是纯损失）。
    case none
    /// 原文保留（不折叠进摘要）。
    case keep
    /// 折叠为自然语言摘要。
    case summarize
    /// 压成摘要 + 指针，正文丢弃。
    case evict
}

/// 内容分类器能力缝（规格 S16 §6.4，服务键 'contentClassifier'）。
///
/// classify 只看单条消息本身（role / content / toolCalls），**不看位置**——
/// 「早期还是近期」由调用方（分层压缩器）遍历时按 recentWindow 决定，
/// 因此分类器不持有索引状态：同一批消息在任何遍历顺序下结论一致。
public protocol ContentClassifier: Sendable {
    /// 判断单条消息的类别。
    func classify(_ message: LlmMessage) -> MessageCategory

    /// 类别对应的压缩策略。
    func strategyFor(_ category: MessageCategory) -> CompressionStrategy

    /// 对话消息的近期窗口（条数）：距末尾不超过该条数的对话算「近期」。
    var recentWindow: Int { get }
}

/// 规则驱动的分类器（规格 S16 §6.4）：角色 + 关键词，全部可解释。
///
/// 判定规则：tool → toolResult；system → 技能关键词 skillList / 工具关键词
/// toolDefinition / 否则 systemPrompt；带 toolCalls 的 assistant →
/// recentConversation（工具调用轨迹的一部分，压掉会切断调用配对）；其余
/// user / assistant → 命中偏好关键词为 userPreference，否则 recentConversation。
/// userTask 与位置类别不由规则产出，交由分层压缩器按 recentWindow 处理。
public struct RuleBasedContentClassifier: ContentClassifier {
    /// 对话消息的近期窗口（条数），缺省 20。
    public let recentWindow: Int

    public init(recentWindow: Int = 20) {
        self.recentWindow = recentWindow
    }

    public func classify(_ message: LlmMessage) -> MessageCategory {
        if let structural = structuralCategory(of: message) {
            return structural
        }
        if preferenceHit(message.content) {
            return .userPreference
        }
        return .recentConversation
    }

    public func strategyFor(_ category: MessageCategory) -> CompressionStrategy {
        strategies[category] ?? .keep
    }

    private func structuralCategory(of message: LlmMessage) -> MessageCategory? {
        if message.role == "tool" { return .toolResult }
        if message.role == "system" { return systemCategory(message.content) }
        if !message.toolCalls.isEmpty { return .recentConversation }
        return nil
    }

    private func systemCategory(_ content: String) -> MessageCategory {
        if skillHit(content) { return .skillList }
        if toolHit(content) { return .toolDefinition }
        return .systemPrompt
    }

    // REASON: 策略与关键词为静态映射表例外（全局 AGENTS.md §6）。
    private let strategies: [MessageCategory: CompressionStrategy] = [
        .systemPrompt: .none,
        .toolDefinition: .none,
        .skillList: .none,
        .toolResult: .evict,
        .userPreference: .keep,
        .userTask: .keep,
        .earlyConversation: .summarize,
        .recentConversation: .keep,
    ]

    private func preferenceHit(_ content: String) -> Bool {
        content.firstMatch(of: /记住|以后都|今后|我喜欢|我不喜欢|不要|务必|始终|偏好/.ignoresCase()) != nil
    }

    private func skillHit(_ content: String) -> Bool {
        content.firstMatch(of: /技能|skill/.ignoresCase()) != nil
    }

    private func toolHit(_ content: String) -> Bool {
        content.firstMatch(of: /工具|tool/.ignoresCase()) != nil
    }
}

/// 'contentClassifier' 服务键。
extension ServiceKey where Service == any ContentClassifier {
    public static let contentClassifier = ServiceKey<any ContentClassifier>("contentClassifier")
}

/// 把 ContentClassifier 作为 'contentClassifier' 服务提供到上下文；
/// 缺省 RuleBasedContentClassifier。
@ContextTreeActor
@discardableResult
public func provideContentClassifier(
    _ ctx: Context,
    classifier: (any ContentClassifier)? = nil
) throws -> any ContentClassifier {
    let resolved = classifier ?? RuleBasedContentClassifier()
    try ctx.provide(.contentClassifier, resolved)
    return resolved
}
