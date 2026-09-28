import Foundation
import SwiftusAgent
import SwiftusCore
import SwiftusFoundation
import Testing

/// 规格 S16 §6.5 golden fixtures：skill 沉淀（命名 / 元信息解析 / 占位符注入 /
/// 提取与审批·安全边界 / 记忆持久化恢复）。
@Suite("S16 skill fixtures")
struct S16SkillFixtureTests {
    private static let fixtures = S16FixtureLoader.loadAllOrEmpty()

    @Test("skill", arguments: Self.fixtures.filter { $0.kind == "skill" })
    @ContextTreeActor
    func skill(_ fixture: S16Fixture) async throws {
        try checkNameCases(fixture)
        try await checkMetaCases(fixture)
        let expect = fixture.raw["expect"]?.objectValue ?? [:]

        // 占位符注入端到端。
        let placeholderTools = ToolRegistry()
        _ = try placeholderTools.register(EchoTool())
        let skill = SkillTool(
            name: "greet",
            description: "问候",
            steps: [
                SkillStep(toolName: "echo", arguments: ["text": .string("你好 {{name}}！")]),
                SkillStep(toolName: "echo", arguments: ["text": .string("再见 {{name}}")]),
            ],
            tools: placeholderTools
        )
        #expect(skill.params.map(\.name) == (expect["skillParams"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        let result = try await skill.call(ToolContext(ToolCall(
            name: "greet",
            arguments: ["name": .string("小明")]
        )))
        #expect(result.content == expect["skillResultContent"]?.stringValue)
        #expect(result.value == expect["skillResultValue"])

        // 提取沉淀与安全/审批边界。
        let library = try SkillLibrary(threshold: 3)
        for index in 0..<3 {
            library.recordTools("任务\(index)", ["echo"])
        }
        let extractTools = ToolRegistry()
        _ = try extractTools.register(EchoTool())
        let extracted = try await library.maybeExtract(tools: extractTools)
        #expect(extracted?.name == expect["extractedName"]?.stringValue)
        #expect((extractTools.get(extracted?.name ?? "") != nil) == (expect["extractedRegistered"] == .bool(true)))

        let safeLibrary = try SkillLibrary(threshold: 1)
        safeLibrary.recordTools("高危", ["risky"])
        let safeTools = ToolRegistry()
        _ = try safeTools.register(EchoTool())
        _ = try safeTools.register(GatedTool("risky", .high))
        #expect((try await safeLibrary.maybeExtract(tools: safeTools) == nil) == (expect["highRiskNotExtracted"] == .bool(true)))

        let deniedLibrary = try SkillLibrary(threshold: 1, approval: AutoApproval(false))
        deniedLibrary.recordTools("审批拒绝", ["echo"])
        let deniedTools = ToolRegistry()
        _ = try deniedTools.register(EchoTool())
        #expect((try await deniedLibrary.maybeExtract(tools: deniedTools) == nil) == (expect["deniedNotExtracted"] == .bool(true)))

        // 记忆持久化 + 恢复。
        let memory = try MemoryStore()
        let persistedLibrary = try SkillLibrary(threshold: 1, memory: memory)
        persistedLibrary.recordTools("记忆", ["echo"])
        let persistTools = ToolRegistry()
        _ = try persistTools.register(EchoTool())
        _ = try await persistedLibrary.maybeExtract(tools: persistTools)
        let freshTools = ToolRegistry()
        _ = try freshTools.register(EchoTool())
        let restored = try await persistedLibrary.restore(tools: freshTools)
        #expect(restored == expect["restored"]?.intValue)
        #expect((freshTools.get("skill_echo") != nil) == (expect["restoredRegistered"] == .bool(true)))
    }

    @ContextTreeActor
    private func checkNameCases(_ fixture: S16Fixture) throws {
        for caseItem in fixture.raw["nameCases"]?.arrayValue ?? [] {
            let input = caseItem["input"]?.stringValue ?? ""
            let expected = caseItem["expect"]?.stringValue ?? ""
            #expect(skillNameFrom(input) == expected)
        }
    }

    @ContextTreeActor
    private func checkMetaCases(_ fixture: S16Fixture) async throws {
        for caseItem in fixture.raw["metaCases"]?.arrayValue ?? [] {
            let input = caseItem["input"]?.stringValue ?? ""
            let tools = caseItem["tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let expected = caseItem["expect"]?.objectValue ?? [:]
            let meta = try await parseSkillMeta(input, tools: tools)
            #expect(meta.name == expected["name"]?.stringValue)
            #expect(meta.description == expected["description"]?.stringValue)
        }
    }
}

/// 回显工具。
@ContextTreeActor
private final class EchoTool: Tool {
    let name = "echo"
    let description = "回显"

    func call(_ context: ToolContext) async throws -> ToolResult {
        let text = context.arguments["text"]?.stringValue ?? ""
        return .success(text, value: .string(text))
    }
}
