import SwiftusCore
import SwiftusFoundation
import Testing

@ContextTreeActor
private final class DangerTool: Tool {
    let name = "danger"
    let description = "高危"
    let riskLevel: ToolRisk = .high

    func call(_ context: ToolContext) async throws -> ToolResult {
        .success("boom")
    }
}

/// 规格 S5 §9:分组注册、风险分级守卫与分组投影。
@ContextTreeActor
@Suite("ToolGroups 分组与分级")
struct ToolGroupsTests {
    @Test("group:整组注册与逆序撤销;groups / namesIn / groupOf")
    func groupLifecycle() throws {
        let registry = ToolRegistry()
        let disposer = try registry.group("web", [EchoTool(), DangerTool()])
        #expect(registry.groups == ["web"])
        #expect(registry.namesIn("web") == ["echo", "danger"])
        #expect(registry.groupOf("echo") == "web")
        #expect(registry.describeGroup("web").count == 2)
        try disposer()
        try disposer()
        #expect(registry.names.isEmpty)
        #expect(registry.groups.isEmpty)
    }

    @Test("guardRisk:越级拒绝,同级放行")
    func guardRisk() async throws {
        let registry = ToolRegistry()
        try registry.register(EchoTool())
        try registry.register(DangerTool())
        registry.guardRisk(.low)
        let denied = await registry.call(ToolCall(name: "danger"))
        #expect(denied.error?.code == ToolError.Codes.toolDenied)
        #expect(denied.content == "工具 \"danger\" 风险等级 high 高于允许的 low")

        let allowed = await registry.call(ToolCall(name: "echo", arguments: ["text": .string("x")]))
        #expect(allowed.failed == false)
    }

    @Test("describeWithin:只投影风险不高于上限的工具")
    func describeWithin() throws {
        let registry = ToolRegistry()
        try registry.register(EchoTool())
        try registry.register(DangerTool())
        #expect(registry.describeWithin(.low).count == 1)
        #expect(registry.describeWithin(.high).count == 2)
    }
}
