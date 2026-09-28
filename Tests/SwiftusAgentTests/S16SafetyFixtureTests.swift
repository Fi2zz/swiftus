import Foundation
import SwiftusAgent
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM
import Testing

/// 规格 S16 §6 golden fixtures：approval-flow / sub-agent / recovery。
@Suite("S16 执行安全组 fixtures")
struct S16SafetyFixtureTests {
    private static let fixtures = S16FixtureLoader.loadAllOrEmpty()

    @Test("approval-flow", arguments: Self.fixtures.filter { $0.kind == "approval-flow" })
    @ContextTreeActor
    func approvalFlow(_ fixture: S16Fixture) async throws {
        let cases = fixture.cases
        let ctx = Context.root()
        defer { ctx.dispose() }
        let gate = AutoApproval(false)
        let registry = ToolRegistry()
        _ = try registry.register(GatedTool("delete", .high))
        _ = try registry.register(GatedTool("echo", .medium))
        try ctx.provide(.tools, registry)
        try provideApproval(ctx, approval: gate)
        let denied = await registry.call(ToolCall(name: "delete"))
        let passed = await registry.call(ToolCall(name: "echo"))
        let first = cases[0]["expect"]?.objectValue ?? [:]
        #expect(denied.failed == (first["deniedFailed"] == .bool(true)))
        #expect(denied.error?.code == first["deniedCode"]?.stringValue)
        #expect(gate.requests == first["requests"]?.intValue)
        #expect(passed.failed == (first["passedFailed"] == .bool(true)))

        let prectx = Context.root()
        defer { prectx.dispose() }
        let preapprove = PreapproveAllApproval()
        let preregistry = ToolRegistry()
        _ = try preregistry.register(GatedTool("read_file", .low, pathParams: ["path"]))
        try prectx.provide(.tools, preregistry)
        try provideApproval(prectx, approval: preapprove)
        let preResult = await preregistry.call(ToolCall(
            name: "read_file",
            arguments: ["path": .string("/etc/hosts")]
        ))
        let second = cases[1]["expect"]?.objectValue ?? [:]
        #expect(preResult.failed == (second["failed"] == .bool(true)))
        #expect(preapprove.requests == second["requests"]?.intValue)

        let askctx = Context.root()
        defer { askctx.dispose() }
        let ask = CliAskUser(writer: { _ in })
        let askGate = AskUserApproval(askUser: ask, timeout: 5)
        let askRegistry = ToolRegistry()
        _ = try askRegistry.register(GatedTool("delete", .high))
        try askctx.provide(.tools, askRegistry)
        try provideApproval(askctx, approval: askGate)
        let approvedFuture = Task { await askRegistry.call(ToolCall(name: "delete")) }
        try await Task.sleep(for: .milliseconds(20))
        ask.submit("y")
        let approved = await approvedFuture.value
        let deniedFuture = Task { await askRegistry.call(ToolCall(name: "delete")) }
        try await Task.sleep(for: .milliseconds(20))
        ask.submit("n")
        let askDenied = await deniedFuture.value
        let third = cases[2]["expect"]?.objectValue ?? [:]
        #expect(approved.failed == (third["approvedFailed"] == .bool(true)))
        #expect(askDenied.failed == (third["deniedFailed"] == .bool(true)))
        #expect(askDenied.error?.code == third["deniedCode"]?.stringValue)
    }

    @Test("sub-agent", arguments: Self.fixtures.filter { $0.kind == "sub-agent" })
    @ContextTreeActor
    func subAgent(_ fixture: S16Fixture) async throws {
        let expect = fixture.raw["expect"]?.objectValue ?? [:]
        let ctx = Context.root()
        defer { ctx.dispose() }
        let session = try Session(id: "main")
        let scripted = ScriptedProvider([
            scriptedCall("c0", "spawn_agent", args: #"{"task":"现在几点","tools":["get_time"]}"#),
            scriptedCall("c1", "get_time"),
            scriptedText("12:00"),
            scriptedText("子任务完成：12:00"),
        ])
        let registry = ToolRegistry()
        _ = try registry.register(GetTimeTool())
        let spawner = SpawnAgentTool(
            host: ctx,
            llm: scripted,
            tools: registry,
            defaultTools: ["get_time"]
        )
        _ = try registry.register(spawner)
        var config = AgentLoop.Config()
        config.session = session
        let loop = AgentLoop(llm: scripted, tools: registry, config: config)
        let turn = try await loop.run("现在几点")
        #expect(turn.reply == expect["reply"]?.stringValue)
        #expect(turn.steps.count == expect["steps"]?.intValue)
        #expect(turn.steps.first?.call.name == expect["stepTool"]?.stringValue)
        #expect(session.events.map(\.type) == (expect["mainEventTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        #expect(scripted.calls.count == expect["mainModelCalls"]?.intValue)
    }

    @Test("recovery", arguments: Self.fixtures.filter { $0.kind == "recovery" })
    @ContextTreeActor
    func recovery(_ fixture: S16Fixture) async throws {
        let expect = fixture.raw["expect"]?.objectValue ?? [:]
        let store = MemorySnapshotStore()
        let service = RecoveryService(store: store)
        let session = try Session(id: "s1")
        try session.append(SessionEventKind.userMessage, data: .object(["text": .string("你好")]))
        try session.append(SessionEventKind.assistantMessage, data: .object(["text": .string("在的")]))
        try await service.snapshot(session)
        let restored = try await service.restore("s1")
        #expect(restored.events.map(\.type) == (expect["restoredTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        #expect(restored.events.map(\.seq) == (expect["restoredSeqs"]?.arrayValue?.compactMap(\.intValue) ?? []))
        #expect(try await service.list() == (expect["listed"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        try await service.delete("s1")
        #expect(try await service.list() == (expect["afterDelete"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        do {
            _ = try SessionSnapshot(jsonValue: .object(["version": .int(2), "sessionId": .string("x")]))
            Issue.record("期望版本不符抛错")
        } catch let error as RecoveryError {
            #expect(error.code == expect["versionErrorCode"]?.stringValue)
        }
        await #expect(throws: RecoveryError.self) {
            _ = try await service.load("ghost")
        }
    }
}

/// 固定风险级与路径参数的工具。
@ContextTreeActor
final class GatedTool: Tool {
    let risk: ToolRisk
    let pathParams: [String]

    init(_ name: String, _ risk: ToolRisk, pathParams: [String] = []) {
        self.name = name
        self.risk = risk
        self.pathParams = pathParams
    }

    let name: String
    let description = "探针"

    var riskLevel: ToolRisk { risk }

    func call(_ context: ToolContext) async throws -> ToolResult {
        .success("ok")
    }
}

/// preapproved 恒放行的审批。
@ContextTreeActor
final class PreapproveAllApproval: Approval {
    private(set) var requests = 0

    var pending: AsyncStream<ApprovalRequest> {
        AsyncStream { $0.finish() }
    }

    func preapproved(_ request: ApprovalRequest) async -> Bool {
        true
    }

    func request(_ request: ApprovalRequest) async -> Bool {
        requests += 1
        return false
    }
}
