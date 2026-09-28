import Foundation
import SwiftusCore
import SwiftusFoundation
import Testing

/// 规格 S3 §3:Session append-only 日志语义。
@ContextTreeActor
@Suite("Session 日志")
struct SessionTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("append:seq 从 0 递增,补齐 sessionId 与自动生成 id,time 可注入")
    func appendStampsEvent() throws {
        let session = try Session(id: "s1")
        let first = try session.append("e0", time: t0)
        let second = try session.append("e1", data: .object(["k": .string("v")]))
        #expect(first.seq == 0 && second.seq == 1)
        #expect(first.sessionId == "s1" && first.id != nil)
        #expect(first.time == t0)
        #expect(session.length == 2 && session.lastEventId == second.id)
        #expect(abs(session.createdAt.timeIntervalSinceNow) < 60) // 空日志构造时刻(S3 §3.1)
    }

    @Test("seed 构造:seq 续接末条 seed,createdAt 取首条时间;inheritedEventCount 越界快速失败")
    func seedConstruction() throws {
        let seed = [SessionEvent(seq: 4, type: "x", time: t0)]
        let session = try Session(id: "s2", seed: seed, inheritedEventCount: 1)
        let appended = try session.append("e")
        #expect(appended.seq == 5)
        #expect(session.createdAt == t0)
        #expect(session.ownEvents.map(\.seq) == [5])
        #expect(throws: SessionError.invalidInheritedCount) {
            try Session(id: "s3", seed: seed, inheritedEventCount: 2)
        }
    }

    @Test("appendEvent:重新盖章 sessionId 与 seq,保留 time 与已有 id")
    func appendEventRestamps() throws {
        let original = SessionEvent(seq: 99, type: "x", time: t0, id: "keep-me", sessionId: "other")
        let session = try Session(id: "s1")
        let stamped = try session.appendEvent(original)
        #expect(stamped.seq == 0 && stamped.sessionId == "s1")
        #expect(stamped.time == t0 && stamped.id == "keep-me")
        let anonymous = SessionEvent(seq: 5, type: "y", time: t0)
        let restamped = try session.appendEvent(anonymous)
        #expect(restamped.seq == 1 && restamped.id != nil)
    }

    @Test("关闭:拒绝追加、close 幂等、onClose 已关闭立即回调")
    func closeSemantics() throws {
        let session = try Session(id: "s1")
        var closeCalls = 0
        session.onClose { closeCalls += 1 }
        session.close()
        session.close()
        #expect(closeCalls == 1)
        #expect(throws: SessionError.sessionClosed(id: "s1")) {
            try session.append("x")
        }
        var lateCalls = 0
        session.onClose { lateCalls += 1 }
        #expect(lateCalls == 1)
    }

    @Test("onEvent:只播追加后的事件,撤销幂等,广播基于快照")
    func eventListeners() throws {
        let session = try Session(id: "s1")
        try session.append("before")
        var received: [String] = []
        let disposer = session.onEvent { received.append($0.type) }
        session.onEvent { _ in
            session.onEvent { _ in } // 广播期间注册,当次不受影响（快照语义）
        }
        try session.append("a")
        try disposer()
        try disposer()
        try session.append("b")
        #expect(received == ["a"])
    }

    @Test("read:time 闭区间过滤,nil 端不限")
    func readTimeRange() throws {
        let session = try Session(id: "s1")
        for offset in 0..<3 {
            try session.append("e\(offset)", time: t0.addingTimeInterval(TimeInterval(offset)))
        }
        let ranged = session.read(from: t0.addingTimeInterval(1), to: t0.addingTimeInterval(2))
        #expect(ranged.map(\.type) == ["e1", "e2"])
        #expect(session.read().count == 3)
    }

    @Test("replay:按序回调,日志不改写")
    func replayInOrder() throws {
        let session = try Session(id: "s1")
        try session.append("a")
        try session.append("b")
        var types: [String] = []
        session.replay { types.append($0.type) }
        #expect(types == ["a", "b"])
        #expect(session.length == 2)
    }
}

/// 规格 S3 §3.6:fork 语义。
@ContextTreeActor
@Suite("Session fork")
struct SessionForkTests {
    @Test("默认 fork:全量种子、继承前缀、新 id 计数、与原会话解耦")
    func forkDefaults() throws {
        let session = try Session(id: "s1")
        try session.append("a")
        try session.append("b")
        let forked = try session.fork()
        #expect(forked.id == "s1-fork-1")
        #expect(forked.inheritedEventCount == 2 && forked.ownEvents.isEmpty)
        try forked.append("c")
        #expect(forked.length == 3 && session.length == 2)
        let second = try session.fork()
        #expect(second.id == "s1-fork-2")
    }

    @Test("从 fromEventId 截断种子;找不到事件抛错且 sessionId 为原会话 id(S3 §8 偏离)")
    func forkFromEvent() throws {
        let session = try Session(id: "s1")
        let first = try session.append("a")
        try session.append("b")
        let forked = try session.fork(fromEventId: first.id)
        #expect(forked.length == 1 && forked.events.first?.type == "a")
        #expect(throws: SessionError.eventNotFound(sessionId: "s1", eventId: "missing")) {
            try session.fork(fromEventId: "missing")
        }
    }
}
