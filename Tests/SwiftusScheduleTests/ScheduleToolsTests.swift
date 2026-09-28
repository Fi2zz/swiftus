import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusSchedule
import Testing

/// 规格 S8 §11.2：提醒工具与装配。
@ContextTreeActor
@Suite("schedule 工具")
struct ScheduleToolsTests {
    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    @Test("provideScheduleTools 注册三工具：分组 schedule，create/delete 中风险")
    func registersThreeTools() throws {
        let (ctx, registry) = try makeContext()
        let registered = try provideScheduleTools(ctx)
        #expect(registered.map(\.name) == ["schedule_create", "schedule_list", "schedule_delete"])
        #expect(registry.names == ["schedule_create", "schedule_list", "schedule_delete"])
        #expect(registry.get("schedule_list")?.riskLevel == .low)
        #expect(registry.get("schedule_delete")?.riskLevel == .medium)
        #expect(registry.get("schedule_create")?.group == "schedule")
        ctx.dispose()
    }

    @Test("create 工具 schema 补齐 at 的 oneOf 联合")
    func createSchemaAtUnion() throws {
        let session = try Session(id: "s1")
        let tool = ScheduleCreateTool(schedule: SessionSchedule(session: session, clock: { self.now }))
        let schema = tool.schema
        let at = schema["parameters"]?["properties"]?["at"]
        #expect(at?["oneOf"]?.arrayValue?.count == 2)
        #expect(schema["parameters"]?["required"] == .array([.string("prompt")]))
        // S5 白名单：宿主字段不下发
        #expect(schema["riskLevel"] == nil && schema["group"] == nil)
    }

    @Test("validateCreateArgs：选择器冲突 / 未知键 / 空 prompt / 非法间隔")
    func validateArgs() {
        let base: [String: JSONValue] = ["prompt": .string("提醒")]
        #expect(validateCreateArgs(base.merging(["after_seconds": .int(60)], uniquingKeysWith: { $1 })) == nil)
        let conflict = base.merging(["after_seconds": .int(60), "at": .string("2026-08-06T13:00:00Z")], uniquingKeysWith: { $1 })
        #expect(validateCreateArgs(conflict)?.code == .invalidSelector)
        let unknown = base.merging(["every_seconds": .int(300), "extra": .int(1)], uniquingKeysWith: { $1 })
        #expect(validateCreateArgs(unknown)?.code == .invalidSelector)
        let emptyPrompt: [String: JSONValue] = ["prompt": .string("  "), "after_seconds": .int(60)]
        #expect(validateCreateArgs(emptyPrompt)?.code == .invalidPrompt)
        let zeroDelay = base.merging(["after_seconds": .int(0)], uniquingKeysWith: { $1 })
        #expect(validateCreateArgs(zeroDelay)?.code == .invalidRule)
        let tooFrequent = base.merging(["every_seconds": .int(299)], uniquingKeysWith: { $1 })
        #expect(validateCreateArgs(tooFrequent)?.code == .frequencyTooHigh)
    }

    @Test("delete 工具：id 带空白在进服务层前拒绝（invalid_rule）")
    func deleteRejectsWhitespaceId() async throws {
        let (ctx, registry) = try makeContext()
        try provideScheduleTools(ctx)
        let result = await registry.call(ToolCall(name: "schedule_delete", arguments: ["id": .string(" schedule-1 ")]))
        #expect(result.failed)
        #expect(result.error?.code == ScheduleErrorCode.invalidRule.rawValue)
        ctx.dispose()
    }

    @Test("工具端到端：create → list → delete；删除不存在返回 schedule_not_found")
    func toolsEndToEnd() async throws {
        let (ctx, registry) = try makeContext()
        try provideScheduleTools(ctx)
        let created = await registry.call(ToolCall(name: "schedule_create", arguments: [
            "prompt": .string(" 到点了 "),
            "after_seconds": .int(600),
        ]))
        #expect(!created.failed)
        #expect(created.value?["id"] == .string("schedule-1"))
        #expect(created.value?["scheduledAt"] == .string(formatUtcInstant(now.addingTimeInterval(600))))
        #expect(created.value?["state"] == .string("scheduled"))
        let listed = await registry.call(ToolCall(name: "schedule_list"))
        #expect(listed.value?.arrayValue?.count == 1)
        let deleted = await registry.call(ToolCall(name: "schedule_delete", arguments: ["id": .string("schedule-1")]))
        #expect(deleted.value?["deleted"] == .bool(true))
        let missing = await registry.call(ToolCall(name: "schedule_delete", arguments: ["id": .string("schedule-1")]))
        #expect(missing.value?["deleted"] == .bool(false))
        #expect(missing.value?["code"] == .string(ScheduleErrorCode.notFound.rawValue))
        ctx.dispose()
    }

    /// 装配上下文：Session + 固定时钟 SessionSchedule + ToolRegistry（服务键 schedule/tools）。
    private func makeContext() throws -> (Context, ToolRegistry) {
        let ctx = Context.root()
        let session = try Session(id: "s1")
        try provideSessionSchedule(ctx, session: session, clock: { self.now })
        let registry = ToolRegistry()
        try ctx.provide(.tools, registry)
        return (ctx, registry)
    }
}
