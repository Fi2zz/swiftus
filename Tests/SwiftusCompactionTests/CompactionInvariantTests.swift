import SwiftusCompaction
import SwiftusCore
import SwiftusFoundation
import Testing

/// 规格 S7 §6：压缩日志不变式（对齐 Dart `compaction_invariant_test.dart`；
/// mismatched-id / not-prefix / unclosed 三例由 golden fixtures 覆盖，此处补齐其余）。
@ContextTreeActor
@Suite("压缩日志不变式")
struct CompactionInvariantTests {
    @Test("没有压缩事件的日志通过")
    func plainLogPasses() throws {
        #expect(checkCompactionInvariant(try plainSession(3).events).isEmpty)
    }

    @Test("完整的一次压缩通过")
    func completeCompactionPasses() throws {
        let session = try plainSession(3)
        try appendStart(session, "c1")
        try appendSummary(session, "c1", shadowed: [0])
        try appendEnd(session, "c1")
        #expect(checkCompactionInvariant(session.events).isEmpty)
    }

    @Test("失败的压缩（end 带 error）通过")
    func failedCompactionPasses() throws {
        let session = try plainSession(3)
        try appendStart(session, "c1")
        try appendEnd(session, "c1", error: "boom")
        #expect(checkCompactionInvariant(session.events).isEmpty)
    }

    @Test("start 缺少 compactionId（空 data / 空串 id 同视为缺失）")
    func startMissingId() throws {
        let session = try plainSession(1)
        try session.append(CompactionEventKind.start, data: .object([:]))
        try appendSummary(session, "", shadowed: [0])
        try appendEnd(session, "")
        let violations = checkCompactionInvariant(session.events)
        #expect(violations.contains { $0.contains("缺少 compactionId") })
    }

    @Test("start 未收尾又开了一次")
    func startWhileOpen() throws {
        let session = try plainSession(3)
        try appendStart(session, "c1")
        try appendStart(session, "c2")
        let violations = checkCompactionInvariant(session.events)
        #expect(violations.contains { $0.contains("身份 c1 的压缩还没有收尾") })
    }

    @Test("一次压缩里出现两个 summary")
    func duplicateSummary() throws {
        let session = try plainSession(3)
        try appendStart(session, "c1")
        try appendSummary(session, "c1", shadowed: [0])
        try appendSummary(session, "c1", shadowed: [0, 1])
        try appendEnd(session, "c1")
        let violations = checkCompactionInvariant(session.events)
        #expect(violations.contains { $0.contains("在一次压缩里重复出现") })
    }

    @Test("成功的 end 之前没有 summary")
    func endWithoutSummary() throws {
        let session = try plainSession(3)
        try appendStart(session, "c1")
        try appendEnd(session, "c1")
        let violations = checkCompactionInvariant(session.events)
        #expect(violations.contains { $0.contains("这次压缩没有 compaction/summary") })
    }

    @Test("缺少或非法的 shadowedSeqs（元素非整数）")
    func invalidShadowedSeqs() throws {
        let session = try plainSession(2)
        try appendStart(session, "c1")
        try session.append(CompactionEventKind.summary, data: .object([
            "compactionId": .string("c1"),
            "summary": .string("摘要"),
            "shadowedSeqs": .array([.string("x")]),
            "kept": .int(1),
        ]))
        try appendEnd(session, "c1")
        let violations = checkCompactionInvariant(session.events)
        #expect(violations.contains { $0.contains("缺少 shadowedSeqs") })
    }

    @Test("assert 违规时抛 CompactionInvariantError，修复后通过")
    func assertThrowsOnViolation() throws {
        let session = try plainSession(1)
        try appendStart(session, "c1")
        #expect(throws: CompactionInvariantError.self) {
            try assertCompactionInvariant(session.events)
        }
        try appendEnd(session, "c1", error: "boom")
        try assertCompactionInvariant(session.events)
    }

    private func plainSession(_ count: Int) throws -> Session {
        let session = try Session(id: "s1")
        for index in 0..<count {
            try session.append("e\(index)")
        }
        return session
    }

    private func appendStart(_ session: Session, _ id: String) throws {
        try session.append(CompactionEventKind.start, data: .object([
            "compactionId": .string(id),
            "keepRecent": .int(1),
        ]))
    }

    private func appendSummary(_ session: Session, _ id: String, shadowed: [Int]) throws {
        try session.append(CompactionEventKind.summary, data: .object([
            "compactionId": .string(id),
            "summary": .string("摘要"),
            "shadowedSeqs": .array(shadowed.map { .int(Int64($0)) }),
            "kept": .int(1),
        ]))
    }

    private func appendEnd(_ session: Session, _ id: String, error: String? = nil) throws {
        var data: [String: JSONValue] = ["compactionId": .string(id)]
        if let error {
            data["error"] = .string(error)
        }
        try session.append(CompactionEventKind.end, data: .object(data))
    }
}
