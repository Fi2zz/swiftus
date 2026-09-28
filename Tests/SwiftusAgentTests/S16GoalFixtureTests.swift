import Foundation
import SwiftusAgent
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM
import Testing

/// 规格 S16 §7 golden fixtures：goal 状态机 / 还原 / fork / 工具 / 审批 / 续行驱动器。
@Suite("S16 goal fixtures")
struct S16GoalFixtureTests {
    private static let fixtures = S16FixtureLoader.loadAllOrEmpty()

    @Test("goal-flow", arguments: Self.fixtures.filter { $0.kind == "goal-flow" })
    @ContextTreeActor
    func goalFlow(_ fixture: S16Fixture) async throws {
        let expect = fixture.raw["expect"]?.objectValue ?? [:]

        // 状态机。
        let session = try Session(id: "s1")
        let goal = DefaultGoalService(session: session, defaultMaxRounds: 3)
        let created = try await goal.create("学英语")
        #expect(created.status.rawValue == expect["createdStatus"]?.stringValue)
        let edited = try await goal.edit("学英语每天")
        #expect(edited.text == expect["editedText"]?.stringValue)
        let paused = try await goal.pause()
        #expect(paused.status.rawValue == expect["pausedStatus"]?.stringValue)
        let resumed = try await goal.resume()
        #expect(resumed.status.rawValue == expect["resumedStatus"]?.stringValue)
        try await goal.advanceRound()
        try await goal.advanceRound()
        try await goal.advanceRound()
        let finalState = try #require(goal.current)
        #expect(finalState.round == expect["finalRound"]?.intValue)
        #expect((finalState.status == .blocked) == (expect["finalBlocked"] == .bool(true)))
        #expect(finalState.blockReason == expect["finalBlockReason"]?.stringValue)
        #expect(session.events.map(\.type) == (expect["sessionEventTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        await #expect(throws: GoalException.self) {
            _ = try await goal.create("另一个")
        }

        // cleared 还原与 fork 不继承。
        let clearedSession = try Session(id: "s2")
        let clearedService = DefaultGoalService(session: clearedSession)
        _ = try await clearedService.create("临时目标")
        _ = try await clearedService.clear()
        #expect((restoreGoalState(clearedSession) == nil) == (expect["clearedRestored"] == .bool(true)))
        let forkSession = try Session(id: "s3")
        let forkGoal = DefaultGoalService(session: forkSession)
        _ = try await forkGoal.create("父目标")
        let forked = try forkSession.fork(id: "s3-fork-1")
        #expect((restoreGoalState(forked) == nil) == (expect["forkNotInherited"] == .bool(true)))

        // 工具端到端。
        let ctx = Context.root()
        defer { ctx.dispose() }
        let registry = ToolRegistry()
        try ctx.provide(.tools, registry)
        let toolGoal = DefaultGoalService(session: try Session(id: "s4"))
        try provideGoal(ctx, config: {
            var config = GoalConfig()
            config.goal = toolGoal
            config.tools = registry
            return config
        }())
        let toolReply = await registry.call(ToolCall(name: "create_goal", arguments: ["text": .string("报时")]))
        #expect(toolReply.content == expect["toolReply"]?.stringValue)

        // approval 拒绝。
        let deniedGoal = DefaultGoalService(
            session: try Session(id: "s5"),
            approval: AutoApproval(false)
        )
        _ = try await deniedGoal.create("需确认")
        await #expect(throws: GoalException.self) {
            _ = try await deniedGoal.complete()
        }

        // 续行驱动器。
        let driverSession = try Session(id: "s6")
        let driverGoal = DefaultGoalService(session: driverSession, defaultMaxRounds: 2)
        _ = try await driverGoal.create("驱动目标")
        let driverLlm = ScriptedProvider([scriptedText("回复1"), scriptedText("回复2")])
        var config = AgentLoop.Config()
        config.session = driverSession
        let driverLoop = AgentLoop(llm: driverLlm, tools: ToolRegistry(), config: config)
        let driver = GoalRoundDriver(goal: driverGoal, agent: driverLoop)
        driverLoop.goalDriver = driver
        let driverTurn = try await driverLoop.run("开始")
        let driverFinal = try #require(driverGoal.current)
        #expect(driverTurn.reply == expect["driverReply"]?.stringValue)
        #expect(driverFinal.round == expect["driverRound"]?.intValue)
        #expect((driverFinal.status == .blocked) == (expect["driverBlocked"] == .bool(true)))
        #expect(driverLlm.calls.count == expect["driverModelCalls"]?.intValue)
    }
}
