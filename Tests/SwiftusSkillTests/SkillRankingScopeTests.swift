import SwiftusCore
import SwiftusSkill
import Testing

@ContextTreeActor
func makeSummary(
    _ name: String,
    source: String = "test",
    provider: String = "fake",
    invocable: Bool = true
) -> SkillSummary {
    SkillSummary(
        name: name,
        description: "\(name) 描述",
        source: source,
        provider: provider,
        modelInvocable: invocable
    )
}

@ContextTreeActor
final class FakeSkillProvider: SkillProvider {
    let name: String
    var candidates: [SkillCandidate]
    var definitions: [String: SkillDefinition] = [:]
    var listError: (any Error)?
    private(set) var listCalls = 0

    init(name: String, candidates: [SkillCandidate] = []) {
        self.name = name
        self.candidates = candidates
    }

    func list() async throws -> [SkillCandidate] {
        listCalls += 1
        if let listError { throw listError }
        return candidates
    }

    func load(_ summary: SkillSummary) async throws -> SkillDefinition? {
        definitions[summary.name]
    }
}

/// 规格 S14 §3:层内排序与同名遮蔽。
@ContextTreeActor
@Suite("SkillRanking 排序遮蔽")
struct SkillRankingTests {
    @Test("rank 小者赢;同 rank 按 provider 注册序;结果按名字码位升序")
    func precedence() {
        var warnings: [String] = []
        let ranked = rankSkillCandidates([
            SkillCandidateBatch(providerOrder: 1, candidates: [
                SkillCandidate(summary: makeSummary("zeta", source: "低权", provider: "p2"), rank: 500),
                SkillCandidate(summary: makeSummary("alpha", source: "低权", provider: "p2"), rank: 500),
            ]),
            SkillCandidateBatch(providerOrder: 0, candidates: [
                SkillCandidate(summary: makeSummary("zeta", source: "高权", provider: "p1"), rank: 100),
            ]),
        ], onShadowed: { warnings.append($0) })
        #expect(ranked.map(\.summary.name) == ["alpha", "zeta"])
        #expect(ranked.first { $0.summary.name == "zeta" }?.summary.provider == "p1")
        #expect(warnings == ["技能 \"zeta\" 被 p1 遮蔽：低权 的候选被忽略。"])
    }

    @Test("同 rank 同 provider:内产出序决定输赢")
    func localOrder() {
        let ranked = rankSkillCandidates([
            SkillCandidateBatch(providerOrder: 0, candidates: [
                SkillCandidate(summary: makeSummary("dup", source: "先", provider: "p1"), rank: 0),
                SkillCandidate(summary: makeSummary("dup", source: "后", provider: "p1"), rank: 0),
            ]),
        ])
        #expect(ranked.first?.summary.source == "先")
    }
}

/// 规格 S14 §5:父子快照合并。
@ContextTreeActor
@Suite("SkillScope 作用域合并")
struct SkillScopeTests {
    @Test("父级并入,同名子级赢并上报,visible 过滤")
    func merge() {
        var warnings: [String] = []
        let merged = mergeScopedSummaries(
            parent: [makeSummary("shared", source: "父"), makeSummary("parent-only", source: "父"), makeSummary("hidden", source: "父")],
            own: [makeSummary("shared", source: "子"), makeSummary("own-only", source: "子")],
            visible: { $0.name != "hidden" },
            onShadowed: { warnings.append($0) }
        )
        #expect(merged.map(\.name) == ["own-only", "parent-only", "shared"])
        #expect(merged.first { $0.name == "shared" }?.source == "子")
        #expect(warnings == ["技能 \"shared\" 被本作用域覆盖：父 的候选被忽略。"])
    }

    @Test("visible 缺省全继承;快照相等判定")
    func defaults() {
        let merged = mergeScopedSummaries(parent: [makeSummary("a")], own: [])
        #expect(merged.map(\.name) == ["a"])
        #expect(sameSkillSnapshot(merged, [makeSummary("a")]))
        #expect(!sameSkillSnapshot(merged, [makeSummary("b")]))
    }
}
