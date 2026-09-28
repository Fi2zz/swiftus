import SwiftusCompaction
import SwiftusCore
import SwiftusFoundation
import Testing

/// 规格 S7 §5：工具配对平衡与切点吸附（对齐 Dart `tool_pairing_test.dart` 9 例）。
@ContextTreeActor
@Suite("工具配对平衡")
struct ToolPairingTests {
    @Test("没有工具调用的日志，每个切点都平衡")
    func plainLogBalanced() throws {
        let session = try plainSession(3)
        #expect(try toolPairingBalancedBefore(session, seq: 0))
        #expect(try toolPairingBalancedAfter(session, seq: 2))
    }

    @Test("未闭合工具调用两侧的切点不平衡")
    func openCallUnbalanced() throws {
        let session = try toolPairSession()
        #expect(try toolPairingBalancedBefore(session, seq: 1))
        #expect(try !toolPairingBalancedBefore(session, seq: 2))
        #expect(try !toolPairingBalancedAfter(session, seq: 1))
        #expect(try toolPairingBalancedAfter(session, seq: 2))
    }

    @Test("查询后新增的事件照样计入（增量折叠缓存）")
    func incrementalFold() throws {
        let session = try toolPairSession()
        #expect(try toolPairingBalancedAfter(session, seq: 2))
        try session.append(SessionEventKind.userMessage, data: .object(["text": .string("再问")]))
        #expect(try toolPairingBalancedAfter(session, seq: 2))
        #expect(try toolPairingBalancedAfter(session, seq: 3))
    }

    @Test("seq 不在日志里时抛 seqNotInLog")
    func unknownSeq() throws {
        let session = try plainSession(2)
        #expect(throws: ToolPairingError.seqNotInLog(seq: 9)) {
            try toolPairingBalancedBefore(session, seq: 9)
        }
    }

    @Test("结果先于调用时抛 resultBeforeCall，且不留半推进状态")
    func resultBeforeCall() throws {
        let session = try Session(id: "s1")
        try session.append(SessionEventKind.toolResult, data: .object([
            "callId": .string("c1"),
            "content": .string("结果"),
        ]))
        #expect(throws: ToolPairingError.resultBeforeCall(seq: 0)) {
            try toolPairingBalancedBefore(session, seq: 0)
        }
        #expect(throws: ToolPairingError.resultBeforeCall(seq: 0)) {
            try toolPairingBalancedBefore(session, seq: 0) // 重复查询仍抛（缓存未半推进）
        }
    }

    @Test("balancedCutAtOrBefore:平衡切点原样返回")
    func balancedCutKept() throws {
        let session = try plainSession(5)
        #expect(try balancedCutAtOrBefore(session, cut: 3) == 3)
    }

    @Test("balancedCutAtOrBefore:不平衡切点向前吸附到最近的平衡位置")
    func unbalancedCutSnapped() throws {
        let session = try toolPairSession()
        #expect(try balancedCutAtOrBefore(session, cut: 2) == 1)
        #expect(try balancedCutAtOrBefore(session, cut: 3) == 3)
    }

    @Test("balancedCutAtOrBefore:没有平衡切点时返回 0")
    func noBalancedCut() throws {
        let session = try Session(id: "s1")
        try session.append(SessionEventKind.assistantMessage, data: assistantCallData)
        #expect(try balancedCutAtOrBefore(session, cut: 1) == 0)
        #expect(try balancedCutAtOrBefore(session, cut: 0) == 0)
    }

    private func plainSession(_ count: Int) throws -> Session {
        let session = try Session(id: "s1")
        for index in 0..<count {
            try session.append("e\(index)")
        }
        return session
    }

    /// 用户 → 助手发起一次工具调用 → 工具结果。
    private func toolPairSession() throws -> Session {
        let session = try Session(id: "s1")
        try session.append(SessionEventKind.userMessage, data: .object(["text": .string("查一下")]))
        try session.append(SessionEventKind.assistantMessage, data: assistantCallData)
        try session.append(SessionEventKind.toolResult, data: .object([
            "callId": .string("c1"),
            "content": .string("结果"),
        ]))
        return session
    }

    private var assistantCallData: JSONValue {
        .object([
            "text": .string(""),
            "toolCalls": .array([
                .object([
                    "id": .string("c1"),
                    "name": .string("search"),
                    "arguments": .string("{}"),
                ]),
            ]),
        ])
    }
}
