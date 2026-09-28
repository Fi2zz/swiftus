import Foundation
import SwiftusCompaction
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 分层压缩器（规格 S16 §6.5）：Compactor 的 drop-in 替身，按内容类别分别处理
/// 较早事件，而不是一律压成一段摘要。
///
/// 压缩的交易边界、切点安全与摘要记忆都由 Compactor 承担，本类只覆盖
/// `summarizeFolded`：分层结果替换掉那一次汇总的产出，其余契约完全一致。
/// 产出的摘要是一段分层文本（[历史摘要] / [用户偏好] / [工具结果] / [保留原文]）。
@ContextTreeActor
public final class LayeredCompactor: Compactor {
    /// 内容分类器：决定每类内容的压缩策略。
    public let classifier: any ContentClassifier

    private let telemetry: (any Telemetry)?

    /// classifier 缺省为 RuleBasedContentClassifier；telemetry 为 nil 则不埋点。
    public init(
        keepRecent: Int = 20,
        classifier: (any ContentClassifier)? = nil,
        telemetry: (any Telemetry)? = nil
    ) throws {
        self.classifier = classifier ?? RuleBasedContentClassifier()
        self.telemetry = telemetry
        try super.init(keepRecent: keepRecent)
    }

    public override func summarizeFolded(
        _ fold: CompactionFold,
        summarize: Summarizer
    ) async throws -> CompactionSummary {
        let layers = collect(fold.events)
        let inner = try await summarize(layers.conversation, fold.previous)
        let text = render(inner.text.trimmingCharacters(in: .whitespacesAndNewlines), layers)
        emit(fold, layers, text)
        return CompactionSummary(text, provider: inner.provider, model: inner.model)
    }

    /// context.compacted 埋点。
    private func emit(_ fold: CompactionFold, _ layers: Layers, _ text: String) {
        telemetry?.emit(TelemetryEvent("context.compacted", data: [
            "tokensBefore": .int(Int64(estimateMessagesTokens(deriveAgentMessages(messageEvents(fold.events))))),
            "tokensAfter": .int(Int64(estimateTokens(text))),
            "compacted": .int(Int64(fold.events.count)),
            "kept": .int(Int64(fold.kept)),
            "toolResults": .int(Int64(layers.toolNotes.count)),
            "preferences": .int(Int64(layers.preferences.count)),
        ]))
    }

    /// 分桶：按（类别, 策略）把较早事件归入偏好 / 工具结果 / 摘要 / 保留原文。
    private func collect(_ folded: [SessionEvent]) -> Layers {
        let older = messageEvents(folded)
        let messages = deriveAgentMessages(older)
        let layers = Layers()
        for (index, event) in older.enumerated() {
            let category = categoryOf(messages[index], indexFromEnd: older.count - index)
            layers.add(event, messages[index], category, classifier.strategyFor(category))
        }
        return layers
    }

    /// 只保留「会被 deriveAgentMessages 还原成一条消息」的事件，保证事件与消息
    /// 按下标一一对应。
    private func messageEvents(_ events: [SessionEvent]) -> [SessionEvent] {
        events.filter { event in
            guard case .object = event.data else { return false }
            return event.type == SessionEventKind.userMessage
                || event.type == SessionEventKind.assistantMessage
                || event.type == SessionEventKind.toolResult
        }
    }

    /// 位置修饰：近期窗口内的 recentConversation 保持原判，窗口外升格为早期对话。
    private func categoryOf(_ message: LlmMessage, indexFromEnd: Int) -> MessageCategory {
        let base = classifier.classify(message)
        guard base == .recentConversation else { return base }
        return indexFromEnd > classifier.recentWindow ? .earlyConversation : base
    }

    /// 分层渲染：四段（空段不占位），整体 trim。
    private func render(_ summary: String, _ layers: Layers) -> String {
        var buffer = ""
        writeSection(&buffer, "历史摘要", summary.isEmpty ? [] : [summary])
        writeSection(&buffer, "用户偏好", layers.preferences)
        writeSection(&buffer, "工具结果", layers.toolNotes)
        writeSection(&buffer, "保留原文", layers.retained)
        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeSection(_ buffer: inout String, _ title: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        buffer += "[\(title)]\n"
        for line in lines {
            buffer += "- \(line.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        buffer += "\n"
    }

    /// 分层结果的分桶。
    private final class Layers {
        var preferences: [String] = []
        var toolNotes: [String] = []
        var retained: [String] = []
        var conversation: [SessionEvent] = []

        func add(_ event: SessionEvent, _ message: LlmMessage, _ category: MessageCategory, _ strategy: CompressionStrategy) {
            if strategy == .evict {
                toolNotes.append(toolNote(event, content: message.content))
                return
            }
            if category == .userPreference {
                preferences.append(message.content)
                return
            }
            if strategy == .summarize {
                conversation.append(event)
                return
            }
            retained.append(message.content)
        }

        /// 工具结果压成「工具名 + 结果首行 + 字符数」的一行说明，正文丢弃，
        /// 并指向会话日志里的 tool/result 事件（不额外落盘）。
        private func toolNote(_ event: SessionEvent, content: String) -> String {
            let name = event.data?["name"]?.stringValue ?? "tool"
            return "工具 \(name)：\(headline(content))"
                + "（原结果 \(content.count) 字符，完整内容见会话日志中的 \(SessionEventKind.toolResult) 事件）"
        }

        private func headline(_ content: String) -> String {
            let first = content.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count <= 80 ? trimmed : String(trimmed.prefix(80)) + "…"
        }
    }
}

/// 把 LayeredCompactor 作为 'compaction' 服务提供到上下文（规格 S16 §6.5）。
///
/// 与 provideCompaction（朴素压缩器）二选一：同名服务重复提供会抛错。
/// classifier / telemetry 缺省取上下文里已提供的 'contentClassifier' / 'telemetry'。
@ContextTreeActor
@discardableResult
public func provideLayeredCompaction(
    _ ctx: Context,
    compaction: (any CompactionEngine)? = nil,
    classifier: (any ContentClassifier)? = nil,
    telemetry: (any Telemetry)? = nil
) throws -> LayeredCompactor {
    let resolved: LayeredCompactor
    if let layered = compaction as? LayeredCompactor {
        resolved = layered
    } else {
        resolved = try LayeredCompactor(
            keepRecent: compaction?.keepRecent ?? 20,
            classifier: classifier ?? ctx.get(.contentClassifier),
            telemetry: telemetry ?? ctx.get(.telemetry)
        )
    }
    try ctx.provide(.compaction, resolved)
    return resolved
}
