import Foundation
import SwiftusCore

/// 层内排序与同名遮蔽：把多个 provider 的产出收敛成一份候选列表（规格 S14 §3）。

/// 一个 provider 在某一轮收集里的产出。
public struct SkillCandidateBatch: Sendable {
    /// provider 的注册顺序（运行时技能为 -1）。
    public let providerOrder: Int

    /// 该 provider 产出的候选（provider 内的产出顺序）。
    public let candidates: [SkillCandidate]

    public init(providerOrder: Int, candidates: [SkillCandidate]) {
        self.providerOrder = providerOrder
        self.candidates = candidates
    }
}

/// 按「rank → provider 注册顺序 → provider 内产出顺序」排序，同名只留第一个；
/// 被遮蔽的候选通过 onShadowed 上报。结果按技能名码位升序。
@ContextTreeActor
public func rankSkillCandidates(
    _ batches: [SkillCandidateBatch],
    onShadowed: (@ContextTreeActor (String) -> Void)? = nil
) -> [SkillCandidate] {
    var ranked: [(candidate: SkillCandidate, providerOrder: Int, localOrder: Int)] = []
    var localOrder = 0
    for batch in batches {
        for candidate in batch.candidates {
            ranked.append((candidate, batch.providerOrder, localOrder))
            localOrder += 1
        }
    }
    ranked.sort { lhs, rhs in
        guard lhs.candidate.rank == rhs.candidate.rank else {
            return lhs.candidate.rank < rhs.candidate.rank
        }
        guard lhs.providerOrder == rhs.providerOrder else {
            return lhs.providerOrder < rhs.providerOrder
        }
        return lhs.localOrder < rhs.localOrder
    }

    var winners: [String: SkillCandidate] = [:]
    for entry in ranked {
        let name = entry.candidate.summary.name
        guard let winner = winners[name] else {
            winners[name] = entry.candidate
            continue
        }
        onShadowed?(
            "技能 \"\(name)\" 被 \(winner.summary.provider) 遮蔽："
                + "\(entry.candidate.summary.source) 的候选被忽略。"
        )
    }
    return winners.values.sorted { $0.summary.name < $1.summary.name }
}
