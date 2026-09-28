import Foundation
import SwiftusCore
import SwiftusFoundation

/// 压缩配置错误（规格 S7 §2；Dart ArgumentError 的结构化对应物）。
public enum CompactionError: Error, Equatable {
    /// keepRecent 为负（构造或调用级覆盖）。
    case negativeKeepRecent(Int)
}

/// 一次压缩的进行态：身份、开始事件、切点、保留条数与上一版摘要（规格 S7 §3）。
private struct CompactionTxn {
    let id: String
    let start: SessionEvent
    let cut: Int
    let kept: Int
    let previous: String
}

/// 基础压缩器：按预算折叠较早事件（规格 S7 §3）。
///
/// 日志本身不被改写：被折叠的事件仍在日志里，压缩只是在末尾追加三个记录事件，
/// 使「发给模型的这段摘要从哪来」可以从日志重建。
/// 非 final 且 open：`summarizeFolded` 是分层压缩器（SwiftusAgent LayeredCompactor）的
/// 覆盖点（对齐 Dart `LayeredCompactor extends Compactor`）。
@ContextTreeActor
open class Compactor: CompactionEngine {
    /// 保留为原始日志的最近事件数（实例预算）。
    public let keepRecent: Int

    /// 会话 id → 滚动摘要的进程内表（规格 S7 §2：摘要记忆不从日志重建）。
    private var summaries: [String: String] = [:]

    /// 构造压缩器；keepRecent 为负时快速失败。
    public init(keepRecent: Int = 20) throws {
        guard keepRecent >= 0 else {
            throw CompactionError.negativeKeepRecent(keepRecent)
        }
        self.keepRecent = keepRecent
    }

    public func summaryOf(_ sessionId: String) -> String? {
        summaries[sessionId]
    }

    public func forget(_ sessionId: String) {
        summaries.removeValue(forKey: sessionId)
    }

    @discardableResult
    public func compactIfNeeded(
        _ session: Session,
        summarize: Summarizer,
        keepRecent override: Int? = nil
    ) async throws -> CompactionResult? {
        let keep = override ?? keepRecent
        guard keep >= 0 else {
            throw CompactionError.negativeKeepRecent(keep)
        }
        let total = session.length
        let cut = try balancedCutAtOrBefore(session, cut: total - keep)
        guard cut > 0 else { return nil }
        let compactionId = CompactionIds.next()
        let start = try session.append(CompactionEventKind.start, data: .object([
            "compactionId": .string(compactionId),
            "keepRecent": .int(Int64(keep)),
        ]))
        let txn = CompactionTxn(
            id: compactionId,
            start: start,
            cut: cut,
            kept: total - cut,
            previous: summaries[session.id] ?? ""
        )
        do {
            return try await commit(session, txn: txn, summarize: summarize)
        } catch {
            _ = try session.append(CompactionEventKind.end, data: .object([
                "compactionId": .string(compactionId),
                "error": .string("\(error)"),
            ]))
            throw error
        }
    }

    /// 把待折叠的事件交给汇总器；分层压缩器的覆盖点（规格 S7 §3，open 供
    /// SwiftusAgent 的 LayeredCompactor 覆盖）。
    open func summarizeFolded(_ fold: CompactionFold, summarize: Summarizer) async throws -> CompactionSummary {
        try await summarize(fold.events, fold.previous)
    }

    private func commit(_ session: Session, txn: CompactionTxn, summarize: Summarizer) async throws -> CompactionResult {
        let folded = Array(session.events.prefix(txn.cut))
        let summary = try await summarizeFolded(
            CompactionFold(events: folded, previous: txn.previous, kept: txn.kept),
            summarize: summarize
        )
        let shadowed = folded.map(\.seq)
        let record = try session.append(
            CompactionEventKind.summary,
            data: summaryPayload(txn, summary: summary, shadowed: shadowed)
        )
        let end = try session.append(CompactionEventKind.end, data: .object([
            "compactionId": .string(txn.id),
        ]))
        summaries[session.id] = summary.text
        return CompactionResult(
            compactionId: txn.id,
            startSeq: txn.start.seq,
            summarySeq: record.seq,
            endSeq: end.seq,
            summary: summary.text,
            shadowedSeqs: shadowed,
            kept: txn.kept
        )
    }

    private func summaryPayload(_ txn: CompactionTxn, summary: CompactionSummary, shadowed: [Int]) -> JSONValue {
        var object: [String: JSONValue] = [
            "compactionId": .string(txn.id),
            "summary": .string(summary.text),
            "shadowedSeqs": .array(shadowed.map { .int(Int64($0)) }),
            "kept": .int(Int64(txn.kept)),
        ]
        if let provider = summary.provider {
            object["provider"] = .string(provider)
        }
        if let model = summary.model {
            object["model"] = .string(model)
        }
        return .object(object)
    }
}

/// 'compaction' 服务键。
extension ServiceKey where Service == any CompactionEngine {
    public static let compaction = ServiceKey<any CompactionEngine>("compaction")
}

/// 把压缩器作为 'compaction' 服务提供到上下文（规格 S7 §2）；缺省构造 Compactor。
@ContextTreeActor
@discardableResult
public func provideCompaction(_ ctx: Context, engine: (any CompactionEngine)? = nil) throws -> any CompactionEngine {
    let resolved = try engine ?? Compactor()
    try ctx.provide(.compaction, resolved)
    return resolved
}
