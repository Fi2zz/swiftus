import Foundation
import SwiftusCore
import SwiftusFoundation

/// 工具配对错位（规格 S7 §5；Dart StateError 的结构化对应物）。
public enum ToolPairingError: Error, Equatable {
    /// `tool/result` 先于其调用出现（日志错位）。
    case resultBeforeCall(seq: Int)
    /// 查询的 seq 不在会话日志里。
    case seqNotInLog(seq: Int)
}

/// 单个会话的增量平衡状态（规格 S7 §5.1）。
///
/// N 条事件有 N + 1 个切点：`cutBalanced` 的第 i 项是第 i 条事件**之前**的
/// 切点，末项是尾切点。
@ContextTreeActor
final class ToolPairingBalance {
    /// 已折叠进 cutBalanced 的事件条数。
    private(set) var folded = 0
    /// 各切点的平衡标记。
    private(set) var cutBalanced: [Bool] = [true]
    /// 各事件 seq 在日志中的下标。
    private(set) var indexBySeq: [Int: Int] = [:]
    /// 尾切点处尚未闭合的工具调用数。
    private var inProgressCalls = 0

    /// 折叠 session 尚未进入缓存的尾部事件。
    ///
    /// 先校验完整尾部再落缓存：日志出现「结果先于调用」的错位时抛错，
    /// 且不留下半推进的状态（规格 S7 §5.1）。
    func extend(with session: Session) throws {
        let events = session.events
        var pending: [Bool] = []
        var inProgress = inProgressCalls
        for event in events.dropFirst(folded) {
            inProgress += Self.delta(of: event)
            guard inProgress >= 0 else {
                throw ToolPairingError.resultBeforeCall(seq: event.seq)
            }
            pending.append(inProgress == 0)
        }
        for index in folded..<events.count {
            indexBySeq[events[index].seq] = index
        }
        folded = events.count
        cutBalanced.append(contentsOf: pending)
        inProgressCalls = inProgress
    }

    /// 一条事件对「未闭合工具调用数」的增量（规格 S7 §5.1）。
    static func delta(of event: SessionEvent) -> Int {
        if event.type == SessionEventKind.assistantMessage {
            return openCalls(of: event.data)
        }
        if event.type == SessionEventKind.toolResult {
            return -1
        }
        return 0
    }

    /// 助手事件里声明的工具调用数；data 非对象或 toolCalls 非数组时计 0。
    static func openCalls(of data: JSONValue?) -> Int {
        guard let data, case let .object(object) = data else { return 0 }
        guard case let .array(calls) = object["toolCalls"] else { return 0 }
        return calls.count
    }
}

/// 平衡缓存：弱键挂会话（规格 S7 实现注记：替代 Dart 的 Expando，会话释放缓存随之回收）。
@ContextTreeActor
private enum ToolPairingCaches {
    static let table: NSMapTable<Session, ToolPairingBalance> = .init(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )
}

/// session 当前日志对应的平衡状态；只增量折叠新增尾部，不重读全量。
@ContextTreeActor
private func pairingBalance(for session: Session) throws -> ToolPairingBalance {
    let balance = ToolPairingCaches.table.object(forKey: session) ?? ToolPairingBalance()
    if balance.folded != session.length {
        try balance.extend(with: session)
    }
    ToolPairingCaches.table.setObject(balance, forKey: session)
    return balance
}

/// `seq` 之前的切点是否平衡（规格 S7 §5.2）；seq 不在日志或日志错位时抛错。
@ContextTreeActor
public func toolPairingBalancedBefore(_ session: Session, seq: Int) throws -> Bool {
    try cutBalance(of: session, seq: seq, offset: 0)
}

/// `seq` 之后的切点是否平衡（规格 S7 §5.2）。
@ContextTreeActor
public func toolPairingBalancedAfter(_ session: Session, seq: Int) throws -> Bool {
    try cutBalance(of: session, seq: seq, offset: 1)
}

@ContextTreeActor
private func cutBalance(of session: Session, seq: Int, offset: Int) throws -> Bool {
    let balance = try pairingBalance(for: session)
    guard let index = balance.indexBySeq[seq] else {
        throw ToolPairingError.seqNotInLog(seq: seq)
    }
    return balance.cutBalanced[index + offset]
}

/// 把切点吸附到最近的平衡位置：从第 `cut` 个切点（折叠前 `cut` 条事件）向前找
/// 第一个平衡切点，找不到时返回 0（无事可折叠，规格 S7 §5.2）。
@ContextTreeActor
public func balancedCutAtOrBefore(_ session: Session, cut: Int) throws -> Int {
    let balanced = try pairingBalance(for: session).cutBalanced
    var index = min(cut, balanced.count - 1)
    while index > 0 {
        if balanced[index] { return index }
        index -= 1
    }
    return 0
}
