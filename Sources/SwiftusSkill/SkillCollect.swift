import SwiftusCore

/// 技能收集：串行地问每个 provider 要候选，排完序收敛成摘要列表（规格 S14 §3）。
///
/// 单个 provider 抛错只影响它自己：错误经 onWarning 上报，其余 provider 的
/// 产出照常生效。运行时技能以 kSkillRuntimeRank 参与同一轮排序。
@ContextTreeActor
public func collectSkillSummaries(
    providers: [any SkillProvider],
    runtime: [SkillRegistration],
    onWarning: (@ContextTreeActor (String) -> Void)? = nil
) async -> [SkillSummary] {
    var batches: [SkillCandidateBatch] = []
    if !runtime.isEmpty {
        batches.append(SkillCandidateBatch(
            providerOrder: -1,
            candidates: runtime.map {
                SkillCandidate(summary: $0.summary, rank: kSkillRuntimeRank)
            }
        ))
    }
    for (index, provider) in providers.enumerated() {
        let candidates = await listSafely(provider, onWarning: onWarning)
        batches.append(SkillCandidateBatch(providerOrder: index, candidates: candidates))
    }
    return rankSkillCandidates(batches, onShadowed: onWarning).map(\.summary)
}

@ContextTreeActor
private func listSafely(
    _ provider: any SkillProvider,
    onWarning: (@ContextTreeActor (String) -> Void)?
) async -> [SkillCandidate] {
    do {
        return try await provider.list()
    } catch {
        onWarning?("技能 provider \"\(provider.name)\" 列举失败：\(error)")
        return []
    }
}
