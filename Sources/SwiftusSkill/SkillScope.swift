import SwiftusCore

/// 技能作用域：父子快照的合并规则与查找辅助（规格 S14 §5）。

/// 作用域可见性判定：返回 false 的技能对该作用域不存在。
/// 只作用于从父级继承的条目——本注册表自己注册的技能始终可见。
public typealias SkillVisibility = @ContextTreeActor (SkillSummary) -> Bool

/// 合并父级与自身的快照，得到子作用域对外可见的技能集合。
///
/// 父级条目先过 visible（nil 表示全部继承），再与 own 按名字合并：
/// 同名由 own 赢下，被遮蔽的父级条目经 onShadowed 上报。结果按技能名码位升序。
@ContextTreeActor
public func mergeScopedSummaries(
    parent: [SkillSummary],
    own: [SkillSummary],
    visible: SkillVisibility? = nil,
    onShadowed: (@ContextTreeActor (String) -> Void)? = nil
) -> [SkillSummary] {
    var merged: [String: SkillSummary] = [:]
    for summary in parent where visible?(summary) ?? true {
        merged[summary.name] = summary
    }
    for summary in own {
        if let shadowed = merged[summary.name] {
            onShadowed?(
                "技能 \"\(summary.name)\" 被本作用域覆盖："
                    + "\(shadowed.source) 的候选被忽略。"
            )
        }
        merged[summary.name] = summary
    }
    return merged.values.sorted { $0.name < $1.name }
}

/// 在摘要列表里按名字查找；未命中返回 nil。
public func findSkillSummary(_ summaries: [SkillSummary], _ name: String) -> SkillSummary? {
    summaries.first { $0.name == name }
}

/// 两份快照是否逐字段相同（Equatable 字典无序等价，替代 jsonEncode 比较，规格 S14 注记）。
public func sameSkillSnapshot(_ left: [SkillSummary], _ right: [SkillSummary]) -> Bool {
    left == right
}
