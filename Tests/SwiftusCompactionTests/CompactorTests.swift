import SwiftusCompaction
import SwiftusCore
import SwiftusFoundation
import Testing

/// 规格 S7 §2/§3：Compactor 契约语义（与 Dart `compaction_test.dart` 互补；
/// 端到端行为由 S7FixtureTests 经 golden fixtures 覆盖）。
@ContextTreeActor
@Suite("Compactor")
struct CompactorTests {
    @Test("事件数不超过保留数时不压缩（预算切点不为正）")
    func noCompactionWithinBudget() async throws {
        let compactor = try Compactor(keepRecent: 3)
        let session = try plainSession(3)
        let result = try await compactor.compactIfNeeded(session, summarize: { _, _ in
            CompactionSummary("x")
        })
        #expect(result == nil)
        #expect(compactor.summaryOf("s1") == nil)
        #expect(session.length == 3)
    }

    @Test("汇总器收到日志开头的待折叠事件")
    func foldedEvents() async throws {
        let compactor = try Compactor(keepRecent: 2)
        let session = try plainSession(5)
        var foldedTypes: [String] = []
        try await compactor.compactIfNeeded(session, summarize: { events, _ in
            foldedTypes = events.map(\.type)
            return CompactionSummary("摘要")
        })
        #expect(foldedTypes == ["e0", "e1", "e2"])
    }

    @Test("forget 丢弃摘要记忆")
    func forgetDropsSummary() async throws {
        let compactor = try Compactor(keepRecent: 1)
        let session = try plainSession(2)
        try await compactor.compactIfNeeded(session, summarize: { _, _ in CompactionSummary("摘要") })
        compactor.forget("s1")
        #expect(compactor.summaryOf("s1") == nil)
    }

    @Test("keepRecent 为负时构造快速失败；调用级覆盖同")
    func negativeKeepRecent() async throws {
        #expect(throws: CompactionError.negativeKeepRecent(-1)) {
            try Compactor(keepRecent: -1)
        }
        let compactor = try Compactor(keepRecent: 1)
        let session = try plainSession(2)
        await #expect(throws: CompactionError.negativeKeepRecent(-2)) {
            try await compactor.compactIfNeeded(session, summarize: { _, _ in
                CompactionSummary("x")
            }, keepRecent: -2)
        }
    }

    @Test("调用级覆盖预算不影响实例预算")
    func overrideKeepRecent() async throws {
        let compactor = try Compactor(keepRecent: 10)
        let session = try plainSession(5)
        let result = try await compactor.compactIfNeeded(session, summarize: { _, _ in
            CompactionSummary("摘要")
        }, keepRecent: 1)
        #expect(result?.compacted == 4 && result?.kept == 1)
        #expect(compactor.keepRecent == 10)
    }

    @Test("provideCompaction 作为 compaction 服务提供到上下文")
    func provideService() throws {
        let ctx = Context.root()
        let engine = try provideCompaction(ctx)
        let resolved = try ctx.require(.compaction)
        #expect(resolved as AnyObject === engine as AnyObject)
        ctx.dispose()
    }

    private func plainSession(_ count: Int) throws -> Session {
        let session = try Session(id: "s1")
        for index in 0..<count {
            try session.append("e\(index)")
        }
        return session
    }
}
