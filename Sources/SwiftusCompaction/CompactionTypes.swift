import Foundation
import SwiftusCore
import SwiftusFoundation

/// 压缩日志事件名（规格 S7 §4）。三个事件是**纯记录**：只记下一次压缩的边界与
/// 输入，不参与消息派生；被折叠的事件仍在日志里，压缩只在其后追加记录。
public enum CompactionEventKind {
    /// 压缩开始事件：记录本次压缩的身份与预算。
    public static let start = "compaction/start"
    /// 压缩摘要事件：记录本次折叠出的摘要与它覆盖的事件。
    public static let summary = "compaction/summary"
    /// 压缩结束事件：本次压缩收尾；带 `error` 表示这次压缩失败。
    public static let end = "compaction/end"
}

/// 压缩身份生成器（规格 S7 §1）：`cmp-<微秒级 Unix 时间戳>-<进程内单调序号>`。
@ContextTreeActor
public enum CompactionIds {
    private static var sequence: UInt64 = 0

    /// 铸一个新的压缩身份（进程内单调，跨会话唯一）。
    public static func next() -> String {
        defer { sequence += 1 }
        let micros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        return "cmp-\(micros)-\(sequence)"
    }
}

/// 一次汇总的产出：摘要文本与写它的模型（规格 S7 §1）。
public struct CompactionSummary: Sendable, Equatable {
    /// 摘要文本。
    public let text: String
    /// 写摘要的提供方；未知时为 nil。
    public let provider: String?
    /// 写摘要的模型；未知时为 nil。
    public let model: String?

    public init(_ text: String, provider: String? = nil, model: String? = nil) {
        self.text = text
        self.provider = provider
        self.model = model
    }
}

/// 汇总器（规格 S7 §1）：接收待折叠的事件与上一版摘要，返回本次汇总产出。
/// 由调用方注入（通常是 llm 能力）。
public typealias Summarizer = @ContextTreeActor ([SessionEvent], String) async throws -> CompactionSummary

/// 一次折叠的输入（规格 S7 §1）。
public struct CompactionFold: Sendable {
    /// 待折叠的事件（日志开头的一段）。
    public let events: [SessionEvent]
    /// 上一版滚动摘要；首次压缩时为空串。
    public let previous: String
    /// 本次压缩后保留为原文的事件数。
    public let kept: Int

    public init(events: [SessionEvent], previous: String, kept: Int) {
        self.events = events
        self.previous = previous
        self.kept = kept
    }
}

/// 一次压缩的结局（规格 S7 §1）。
public struct CompactionResult: Sendable, Equatable {
    /// 本次压缩的身份（与日志中三个事件的 compactionId 一致）。
    public let compactionId: String
    /// `compaction/start` 事件的 seq。
    public let startSeq: Int
    /// `compaction/summary` 事件的 seq。
    public let summarySeq: Int
    /// `compaction/end` 事件的 seq。
    public let endSeq: Int
    /// 产出的滚动摘要。
    public let summary: String
    /// 被折叠进摘要的事件 seq（按日志顺序）。
    public let shadowedSeqs: [Int]
    /// 本次压缩后保留为原文的事件数。
    public let kept: Int

    public init(
        compactionId: String,
        startSeq: Int,
        summarySeq: Int,
        endSeq: Int,
        summary: String,
        shadowedSeqs: [Int],
        kept: Int
    ) {
        self.compactionId = compactionId
        self.startSeq = startSeq
        self.summarySeq = summarySeq
        self.endSeq = endSeq
        self.summary = summary
        self.shadowedSeqs = shadowedSeqs
        self.kept = kept
    }

    /// 被折叠的事件数。
    public var compacted: Int {
        shadowedSeqs.count
    }
}
