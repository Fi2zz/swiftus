import SwiftusCore
import SwiftusFoundation

/// 目录段在 system prompt 里的名字。
public let kSkillCatalogSectionName = "skills"

/// 目录段在 system prompt 里的默认排序权重。
public let kSkillCatalogSectionOrder = 50

/// 跟随注册表，把可用技能目录挂成一段 system prompt（规格 S14 §6）。
///
/// 目录为空时撤销该段——没有技能时 prompt 与本插件不存在时逐字相同。
@ContextTreeActor
public final class SkillCatalogSection {
    /// 技能来源。
    public let registry: SkillRegistry

    /// 目标 system prompt。
    public let prompt: SystemPrompt

    /// 段的排序权重。
    public let order: Int

    /// 目录里单条描述的长度上限。
    public let descriptionMaxLength: Int

    private var section: Disposer?
    private var name = kSkillCatalogSectionName
    private var listenerToken: Int?

    public init(
        registry: SkillRegistry,
        prompt: SystemPrompt,
        order: Int = kSkillCatalogSectionOrder,
        descriptionMaxLength: Int = kSkillCatalogDescriptionMaxLength
    ) {
        self.registry = registry
        self.prompt = prompt
        self.order = order
        self.descriptionMaxLength = descriptionMaxLength
    }

    /// 开始跟随注册表；返回撤销函数（幂等）。
    /// name 是挂到 prompt 上的段名：同一份 prompt 上挂多个作用域时各用不同的段名。
    ///
    /// 生命周期与 Dart 一致：注册表的监听强引用本控制器，直到 detach 或注册表释放。
    @discardableResult
    public func attach(name: String = kSkillCatalogSectionName) -> Disposer {
        self.name = name
        listenerToken = registry.onChange { [self] in sync() }
        sync()
        var disposed = false
        return { [weak self] in
            guard let self, !disposed else { return }
            disposed = true
            if let token = self.listenerToken {
                self.registry.removeChangeListener(token)
            }
            self.detachSection()
        }
    }

    /// 按当前快照挂上或摘掉目录段。
    func sync() {
        guard !registry.modelInvocable.isEmpty else {
            detachSection()
            return
        }
        guard section == nil else { return }
        do {
            section = try prompt.section(PromptSection(name: name, order: order, text: { [weak self] in
                self?.renderCurrent() ?? ""
            }))
        } catch {
            registry.reportWarning("技能目录段 \"\(name)\" 挂载失败：\(error)")
        }
    }

    private func renderCurrent() -> String {
        let skills = registry.modelInvocable
        guard !skills.isEmpty else { return "" }
        return renderSkillCatalog(skills, descriptionMaxLength: descriptionMaxLength)
    }

    private func detachSection() {
        let disposer = section
        section = nil
        try? disposer?()
    }
}
