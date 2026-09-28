import SwiftusCore
import SwiftusFoundation

/// 压缩日志不变式被破坏（规格 S7 §6；assert 版抛出，开发模式使用）。
public struct CompactionInvariantError: Error, Equatable, CustomStringConvertible {
    /// 全部违规描述。
    public let violations: [String]

    public init(violations: [String]) {
        self.violations = violations
    }

    public var description: String {
        "压缩日志不变式被破坏：\n\(violations.joined(separator: "\n"))"
    }
}

/// 检查日志里的压缩事件，返回全部违规描述（空数组表示通过，规格 S7 §6）。
///
/// 纯函数：一次压缩的三个事件必须成对、同身份，且 `compaction/summary`
/// 记录的折叠区间确实是日志开头的一段。
public func checkCompactionInvariant(_ events: [SessionEvent]) -> [String] {
    var scan = InvariantScan()
    var violations: [String] = []
    for event in events {
        scan.check(event, in: events, violations: &violations)
    }
    scan.checkClosed(&violations)
    return violations
}

/// 断言不变式，违规时抛 `CompactionInvariantError`（规格 S7 §6）。
public func assertCompactionInvariant(_ events: [SessionEvent]) throws {
    let violations = checkCompactionInvariant(events)
    guard violations.isEmpty else {
        throw CompactionInvariantError(violations: violations)
    }
}

/// 不变式扫描状态机（规格 S7 §6.2）：进行中的压缩身份 + 本次是否已见 summary。
private struct InvariantScan {
    var openId: String?
    var summarized = false

    mutating func check(_ event: SessionEvent, in all: [SessionEvent], violations: inout [String]) {
        if event.type == CompactionEventKind.start {
            return checkStart(event, &violations)
        }
        if event.type == CompactionEventKind.summary {
            return checkSummary(event, in: all, &violations)
        }
        if event.type == CompactionEventKind.end {
            return checkEnd(event, &violations)
        }
    }

    /// 扫描收尾：日志结束仍有未收尾压缩即违规（规格 S7 §6.1 #7）。
    func checkClosed(_ violations: inout [String]) {
        guard let openId else { return }
        violations.append("身份 \(openId) 的压缩没有 \(CompactionEventKind.end) 收尾")
    }

    private mutating func checkStart(_ event: SessionEvent, _ violations: inout [String]) {
        if let openId {
            violations.append("seq \(event.seq) 的 \(CompactionEventKind.start) 之前，身份 \(openId) 的压缩还没有收尾")
        }
        let id = compactionId(of: event)
        if id == nil {
            violations.append("seq \(event.seq) 的 \(CompactionEventKind.start) 缺少 compactionId")
        }
        openId = id
        summarized = false
    }

    private mutating func checkSummary(_ event: SessionEvent, in all: [SessionEvent], _ violations: inout [String]) {
        let id = compactionId(of: event)
        if id == nil || id != openId {
            violations.append("seq \(event.seq) 的 \(CompactionEventKind.summary) 身份 \(id ?? "（缺失）") 与进行中的压缩 \(openId ?? "（无）") 不一致")
        }
        if summarized {
            violations.append("seq \(event.seq) 的 \(CompactionEventKind.summary) 在一次压缩里重复出现")
        }
        checkShadowed(of: event, in: all, &violations)
        summarized = true
    }

    private mutating func checkEnd(_ event: SessionEvent, _ violations: inout [String]) {
        let id = compactionId(of: event)
        if id == nil || id != openId {
            violations.append("seq \(event.seq) 的 \(CompactionEventKind.end) 身份 \(id ?? "（缺失）") 与进行中的压缩 \(openId ?? "（无）") 不一致")
        }
        if !compactionFailed(event), !summarized {
            violations.append("seq \(event.seq) 的 \(CompactionEventKind.end) 没有报错，但这次压缩没有 \(CompactionEventKind.summary)")
        }
        openId = nil
        summarized = false
    }

    private func checkShadowed(of event: SessionEvent, in all: [SessionEvent], _ violations: inout [String]) {
        guard let seqs = shadowedSeqs(of: event), !seqs.isEmpty else {
            violations.append("seq \(event.seq) 的 \(CompactionEventKind.summary) 缺少 shadowedSeqs")
            return
        }
        if all.prefix(seqs.count).map(\.seq) != seqs {
            violations.append("seq \(event.seq) 的 \(CompactionEventKind.summary) 折叠的不是日志开头的一段")
        }
    }
}

/// 事件的压缩身份：data 为对象且 compactionId 为非空字符串，否则为 nil（规格 S7 §6.1 #2）。
private func compactionId(of event: SessionEvent) -> String? {
    guard let text = event.data?["compactionId"]?.stringValue, !text.isEmpty else { return nil }
    return text
}

/// 失败判定：data 为对象且 error 键存在且值非 null（规格 S7 §6.2）。
private func compactionFailed(_ event: SessionEvent) -> Bool {
    guard case let .object(object) = event.data, let error = object["error"] else { return false }
    return error != .null
}

/// shadowedSeqs 载荷：int 数组；缺失 / 非数组 / 元素非整数时为 nil（规格 S7 §6.1 #8）。
private func shadowedSeqs(of event: SessionEvent) -> [Int]? {
    guard case let .array(items) = event.data?["shadowedSeqs"] else { return nil }
    var seqs: [Int] = []
    for item in items {
        guard let seq = item.intValue else { return nil }
        seqs.append(seq)
    }
    return seqs
}
