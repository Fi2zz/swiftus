import SwiftusCore
import SwiftusFoundation
import SwiftusSkill
import Testing

/// 规格 S14 §6 / §8:目录渲染、目录段挂载与正文块渲染。
@ContextTreeActor
@Suite("SkillCatalog 目录与正文")
struct SkillCatalogTests {
    @Test("目录渲染:包裹结构、转义与空白折叠")
    func renderCatalog() {
        let rendered = renderSkillCatalog([
            SkillSummary(name: "a-skill", description: "多行\n描述 & <特殊>", source: "test", provider: "fake"),
        ])
        #expect(rendered.hasPrefix("<system-reminder>\n\(kSkillCatalogIntro)\n\n<available_skills>\n"))
        #expect(rendered.contains("- `a-skill`: 多行 描述 &amp; &lt;特殊&gt;\n"))
        #expect(rendered.hasSuffix("</available_skills>\n\n\(kSkillCatalogInstruction)\n</system-reminder>"))
    }

    @Test("normalizeSkillDescription:折叠空白与超长截断")
    func normalize() {
        #expect(normalizeSkillDescription("a\n b\t c", maxLength: 500) == "a b c")
        let long = String(repeating: "长", count: 600)
        let truncated = normalizeSkillDescription(long, maxLength: 500)
        #expect(truncated.count == 500)
        #expect(truncated.hasSuffix("..."))
    }

    @Test("目录段:空目录不挂段,有技能挂段,清空后摘段")
    func sectionLifecycle() async throws {
        let registry = SkillRegistry()
        let prompt = SystemPrompt()
        let section = SkillCatalogSection(registry: registry, prompt: prompt)
        _ = section.attach()
        #expect(prompt.sectionList.isEmpty)

        try registry.register(SkillRegistration(name: "a-skill", description: "一"))
        await registry.refresh()
        #expect(prompt.sectionList.map(\.name) == ["skills"])
        let assembly = prompt.assemble()
        #expect(prompt.render(assembly).contains("<available_skills>"))

        #expect(registry.available.isEmpty == false)
        let disposer = try registry.register(SkillRegistration(name: "b-skill", description: "二"))
        await registry.refresh()
        try disposer()
        try registry.register(SkillRegistration(name: "temp", description: "x"))
        _ = try registry.register(SkillRegistration(name: "temp2", description: "x"))
        await registry.refresh()
        #expect(prompt.sectionList.map(\.name) == ["skills"])
    }

    @Test("正文块:资源基址四类提示与属性转义")
    func contentBlock() {
        func definition(_ base: SkillResourceBase?) -> SkillDefinition {
            SkillDefinition(
                summary: SkillSummary(name: "a-b", description: "x", source: "test", provider: "fake"),
                content: "指令正文",
                resourceBase: base
            )
        }
        let plain = renderSkillContent(definition(nil))
        #expect(plain.contains("<skill_content name=\"a-b\">"))
        #expect(plain.contains("Resources for this skill are managed by provider \"fake\"."))
        #expect(plain.contains("<skill_instructions>\n指令正文\n</skill_instructions>"))
        #expect(renderSkillContent(definition(.directory("/tmp/skills"))).contains("Base directory for this skill: /tmp/skills"))
        #expect(renderSkillContent(definition(.url("https://x.dev"))).contains("Base URL for this skill: https://x.dev"))
        #expect(renderSkillContent(definition(.opaque("自管"))).contains("Resources for this skill: 自管"))
        #expect(renderSkillContent(definition(nil)).hasSuffix("</skill_content>"))
    }
}

/// 规格 S14 §7:skill 工具的拒绝、未知与成功路径。
@ContextTreeActor
@Suite("SkillLoadTool 工具")
struct SkillLoadToolTests {
    private func makeTool() async throws -> SkillLoadTool {
        let registry = SkillRegistry()
        try registry.register(SkillRegistration(name: "open-skill", description: "开", content: "开放正文"))
        let disabled = SkillRegistration(name: "closed-skill", description: "关", content: "关闭正文")
        try registry.register(disabled)
        await registry.refresh()
        // closed-skill 手动置为不可模型调用
        let registry2 = SkillRegistry()
        try registry2.register(SkillRegistration(name: "open-skill", description: "开", content: "开放正文"))
        await registry2.refresh()
        return SkillLoadTool(registry: registry2)
    }

    @Test("非法名与未知名")
    func invalidAndUnknown() async throws {
        let tool = try await makeTool()
        let invalid = try await tool.call(ToolContext(ToolCall(name: "skill", arguments: ["name": .string("BAD NAME")])))
        #expect(invalid.error?.code == "SKILL_UNAVAILABLE")
        #expect(invalid.error?.message == "invalid skill name \"BAD NAME\"")
        #expect(invalid.content.hasPrefix("{\"code\":\"SKILL_UNAVAILABLE\""))

        let unknown = try await tool.call(ToolContext(ToolCall(name: "skill", arguments: ["name": .string("ghost")])))
        #expect(unknown.error?.code == "SKILL_UNKNOWN")
        #expect(unknown.error?.message == "skill \"ghost\" is unknown or no longer available")
    }

    @Test("成功:渲染 skill_content 并携带 value")
    func success() async throws {
        let tool = try await makeTool()
        let result = try await tool.call(ToolContext(ToolCall(name: "skill", arguments: ["name": .string("open-skill")])))
        #expect(result.failed == false)
        #expect(result.content.contains("<skill_content name=\"open-skill\">"))
        #expect(result.content.contains("开放正文"))
        #expect(result.value?["name"] == .string("open-skill"))
        #expect(result.value?["provider"] == .string("runtime"))
    }

    @Test("不可模型调用的技能被拒绝")
    func notInvocable() async throws {
        let registry = SkillRegistry()
        let provider = FakeSkillProvider(name: "fake", candidates: [
            SkillCandidate(summary: makeSummary("locked", provider: "fake", invocable: false)),
        ])
        try registry.registerProvider(provider)
        await registry.refresh()
        let tool = SkillLoadTool(registry: registry)
        let result = try await tool.call(ToolContext(ToolCall(name: "skill", arguments: ["name": .string("locked")])))
        #expect(result.error?.code == "SKILL_UNAVAILABLE")
        #expect(result.content.contains("is not available for model invocation"))
    }
}
