import SwiftusCore
import SwiftusFoundation

/// 压缩能力缝（规格 S7 §2，服务键 `compaction`）：实现方决定何时压缩、保留多少，
/// 并把更早的历史折叠成一条滚动摘要；消费方只依赖本接口。
@ContextTreeActor
public protocol CompactionEngine: Sendable {
    /// 保留为原始日志的最近事件数（实例预算）。
    var keepRecent: Int { get }

    /// 某会话当前的滚动摘要；尚未压缩过时为 nil。
    func summaryOf(_ sessionId: String) -> String?

    /// 丢弃某会话的摘要记忆。
    func forget(_ sessionId: String)

    /// 事件数超过预算时折叠较早部分并返回结果；没有可折叠的平衡切点时返回 nil（规格 S7 §3）。
    ///
    /// 一次成功的压缩在日志留下 `compaction/start` → `compaction/summary` →
    /// `compaction/end` 三个事件，且切点不劈开工具调用与其结果。汇总器抛错时
    /// `compaction/end` 记下错误、摘要记忆不更新，异常原样上抛。
    /// `keepRecent` 仅覆盖本次调用的预算；负值快速失败。
    @discardableResult
    func compactIfNeeded(
        _ session: Session,
        summarize: Summarizer,
        keepRecent override: Int?
    ) async throws -> CompactionResult?
}

extension CompactionEngine {
    /// 以实例预算折叠（keepRecent 不覆盖）。
    @discardableResult
    public func compactIfNeeded(
        _ session: Session,
        summarize: Summarizer
    ) async throws -> CompactionResult? {
        try await compactIfNeeded(session, summarize: summarize, keepRecent: nil)
    }
}
