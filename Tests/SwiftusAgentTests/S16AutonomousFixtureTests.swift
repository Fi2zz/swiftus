import Foundation
import SwiftusAgent
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM
import Testing

/// 规格 S16 §8 golden fixtures：autonomous 时间窗口 / 优先级 / Runner 停止矩阵。
@Suite("S16 autonomous fixtures")
struct S16AutonomousFixtureTests {
    private static let fixtures = S16FixtureLoader.loadAllOrEmpty()

    @Test("autonomous-flow", arguments: Self.fixtures.filter { $0.kind == "autonomous-flow" })
    @ContextTreeActor
    func autonomousFlow(_ fixture: S16Fixture) async throws {
        try checkWindowCases(fixture)
        try checkPriorityCases(fixture)
        try await checkRunnerCases(fixture)
    }

    @ContextTreeActor
    private func checkWindowCases(_ fixture: S16Fixture) throws {
        let day = try TimeWindow(start: .seconds(9 * 3600), end: .seconds(17 * 3600))
        let night = try TimeWindow(start: .seconds(22 * 3600), end: .seconds(6 * 3600))
        let first = fixture.raw["windowCases"]?.arrayValue?[0]["expect"]?.objectValue ?? [:]
        #expect(day.contains(date(hour: 9)) == (first["at9"] == .bool(true)))
        #expect(day.contains(date(hour: 17)) == (first["at17"] == .bool(true)))
        #expect(day.contains(date(hour: 8, minute: 59)) == (first["at8"] == .bool(true)))
        let second = fixture.raw["windowCases"]?.arrayValue?[1]["expect"]?.objectValue ?? [:]
        #expect(night.contains(date(hour: 23, minute: 30)) == (second["at23"] == .bool(true)))
        #expect(night.contains(date(hour: 1)) == (second["at1"] == .bool(true)))
        #expect(night.contains(date(hour: 12)) == (second["at12"] == .bool(true)))
        #expect(calendarHour(night.nextStart(date(hour: 10))) == second["nextFrom10"]?.intValue)
        #expect(calendarDay(night.nextStart(date(hour: 23))) == second["nextFrom23"]?.intValue)
    }

    @ContextTreeActor
    private func checkPriorityCases(_ fixture: S16Fixture) throws {
        let engine = PriorityEngine()
        let low = Goal(id: "a", text: "低", status: .active, round: 0, maxRounds: 10, createdAt: fixed, updatedAt: fixed)
        let high = Goal(id: "b", text: "高", status: .active, round: 9, maxRounds: 10, createdAt: fixed, updatedAt: fixed)
        let first = fixture.raw["priorityCases"]?.arrayValue?[0]["expect"]?.objectValue ?? [:]
        #expect(engine.scoreOf(low).score == doubleOf(first["scoreA"]))
        #expect(engine.scoreOf(high).score == doubleOf(first["scoreB"]))
        #expect(engine.selectNext([low, high])?.id == first["selected"]?.stringValue)
        let second = fixture.raw["priorityCases"]?.arrayValue?[1]["expect"]?.objectValue ?? [:]
        #expect(engine.selectNext([low, high], importance: ["a": 10])?.id == second["selected"]?.stringValue)
    }

    @ContextTreeActor
    private func checkRunnerCases(_ fixture: S16Fixture) async throws {
        let cases = fixture.raw["runnerCases"]?.arrayValue ?? []

        // 正常完成：maxRounds 2 → 2 轮后达上限自动阻塞 → humanRequired。
        var result = try await runScenario(
            goalMaxRounds: 2,
            script: [scriptedText("回复1"), scriptedText("回复2")],
            policy: DefaultAutonomousPolicy(),
            costTracker: nil
        )
        let first = cases[0]["expect"]?.objectValue ?? [:]
        #expect(result.stoppedReason.rawValue == first["stoppedReason"]?.stringValue)
        #expect(result.turns.count == first["turns"]?.intValue)
        #expect(result.turns.map(\.reply) == (first["replies"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        #expect(result.goalsAdvanced.count == first["advanced"]?.intValue)

        // 预算超限。
        result = try await runScenario(
            goalMaxRounds: 100,
            script: [scriptedText("不该出现")],
            policy: DefaultAutonomousPolicy(dailyBudget: 5),
            costTracker: FixedCostTracker(todayCost: 10)
        )
        let second = cases[1]["expect"]?.objectValue ?? [:]
        #expect(result.stoppedReason.rawValue == second["stoppedReason"]?.stringValue)
        #expect(result.turns.count == second["turns"]?.intValue)

        // 轮次上限。
        result = try await runScenario(
            goalMaxRounds: 100,
            script: [scriptedText("回复1"), scriptedText("回复2"), scriptedText("回复3")],
            policy: DefaultAutonomousPolicy(maxContinuousRounds: 2),
            costTracker: nil
        )
        let third = cases[2]["expect"]?.objectValue ?? [:]
        #expect(result.stoppedReason.rawValue == third["stoppedReason"]?.stringValue)
        #expect(result.turns.count == third["turns"]?.intValue)

        // 运行前停止。
        let session = try Session(id: "r4")
        let goal = DefaultGoalService(session: session)
        _ = try await goal.create("自主目标")
        let llm = ScriptedProvider([scriptedText("不该出现")])
        var config = AgentLoop.Config()
        config.session = session
        let agent = AgentLoop(llm: llm, tools: ToolRegistry(), config: config)
        let runner = DefaultAutonomousRunner(
            agent: agent,
            goal: goal,
            session: session,
            policy: DefaultAutonomousPolicy(),
            clock: { fixed }
        )
        runner.stop()
        result = try await runner.run()
        let fourth = cases[3]["expect"]?.objectValue ?? [:]
        #expect(result.stoppedReason.rawValue == fourth["stoppedReason"]?.stringValue)
        #expect(result.turns.count == fourth["turns"]?.intValue)
    }

    @ContextTreeActor
    private func runScenario(
        goalMaxRounds: Int,
        script: [LlmResult],
        policy: any AutonomousPolicy,
        costTracker: (any CostTracker)?
    ) async throws -> AutonomousResult {
        let session = try Session(id: "scenario-\(UUID().uuidString)")
        let goal = DefaultGoalService(session: session, defaultMaxRounds: goalMaxRounds)
        _ = try await goal.create("自主目标")
        let llm = ScriptedProvider(script)
        var config = AgentLoop.Config()
        config.session = session
        let agent = AgentLoop(llm: llm, tools: ToolRegistry(), config: config)
        let runner = DefaultAutonomousRunner(
            agent: agent,
            goal: goal,
            session: session,
            policy: policy,
            costTracker: costTracker,
            clock: { fixed }
        )
        return try await runner.run()
    }

    private let fixed = Date(timeIntervalSince1970: 1_786_176_000) // 2026-08-06T12:00:00Z

    private func date(hour: Int, minute: Int = 0) -> Date {
        // 本地时区构造（对齐 Dart DateTime 的本地字段语义，与 timeOfDay 的 Calendar.current 一致）。
        Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: hour, minute: minute))!
    }

    private func calendarHour(_ date: Date) -> Int {
        Calendar(identifier: .gregorian).component(.hour, from: date)
    }

    private func calendarDay(_ date: Date) -> Int {
        Calendar(identifier: .gregorian).component(.day, from: date)
    }
}

/// 固定成本追踪器。
@ContextTreeActor
private final class FixedCostTracker: CostTracker {
    let todayCost: Double
    init(todayCost: Double) {
        self.todayCost = todayCost
    }
}

/// JSONValue 数值读取。
private func doubleOf(_ value: JSONValue?) -> Double? {
    if case let .double(number) = value { return number }
    if case let .int(number) = value { return Double(number) }
    return nil
}
