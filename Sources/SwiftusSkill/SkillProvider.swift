import SwiftusCore

/// 一类技能来源：把某个外部存储里的技能列成候选，并按需加载正文（规格 S14 §3）。
///
/// list 在每个发现根上收集候选（rank 决定同名遮蔽）；load 在模型真正需要时
/// 返回正文，返回 nil 表示该技能已消失（注册表据此失效缓存）。
@ContextTreeActor
public protocol SkillProvider {
    /// provider 名，必须 kebab-case，且在注册表内唯一。
    var name: String { get }

    /// 列出当前可见的候选。
    func list() async throws -> [SkillCandidate]

    /// 加载 summary 对应的完整定义。
    func load(_ summary: SkillSummary) async throws -> SkillDefinition?
}

/// provider 列表里按名字查找；未命中返回 nil。
@ContextTreeActor
public func providerNamed(_ providers: [any SkillProvider], _ name: String) -> (any SkillProvider)? {
    providers.first { $0.name == name }
}
