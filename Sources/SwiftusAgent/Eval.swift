import Foundation
import SwiftusCore
import SwiftusLLM

/// evaluation 的类型词汇与默认判分（规格 S16 §6.6）。
///
/// 与具体 Agent 装配解耦：调用方注入一个 EvalRunner（通常是「跑一轮
/// AgentLoop.run」），Evaluator 负责跑 case、判分、汇总 EvalReport。

/// 判分函数：给定 case 与实测结果，返回是否通过。
public typealias EvalJudge = @Sendable (EvalCase, EvalResult) -> Bool

/// 一条评估用例。
public struct EvalCase: Sendable, Equatable {
    /// 用例 id。
    public let id: String
    /// 用户输入。
    public let input: String
    /// 期望调用的工具（须为实际调用集合的子集）。
    public let expectedTools: [String]
    /// 期望输出包含的关键词。
    public let expectedOutput: String?
    /// 最大步数限制。
    public let maxRounds: Int?

    public init(
        id: String,
        input: String,
        expectedTools: [String] = [],
        expectedOutput: String? = nil,
        maxRounds: Int? = nil
    ) {
        self.id = id
        self.input = input
        self.expectedTools = expectedTools
        self.expectedOutput = expectedOutput
        self.maxRounds = maxRounds
    }

    public init(jsonValue: JSONValue) {
        let object = jsonValue.objectValue ?? [:]
        id = object["id"]?.stringValue ?? ""
        input = object["input"]?.stringValue ?? ""
        expectedTools = object["expectedTools"]?.arrayValue?.compactMap(\.stringValue) ?? []
        expectedOutput = object["expectedOutput"]?.stringValue
        maxRounds = object["maxRounds"]?.intValue
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "input": .string(input),
        ]
        if !expectedTools.isEmpty {
            object["expectedTools"] = .array(expectedTools.map { .string($0) })
        }
        if let expectedOutput {
            object["expectedOutput"] = .string(expectedOutput)
        }
        if let maxRounds {
            object["maxRounds"] = .int(Int64(maxRounds))
        }
        return .object(object)
    }
}

/// 一条 case 的实测结果。
public struct EvalResult: Sendable, Equatable {
    /// 用例 id。
    public let caseId: String
    /// 是否通过。
    public let passed: Bool
    /// 实际调用的工具（按序）。
    public let actualTools: [String]
    /// 实际输出。
    public let actualOutput: String
    /// 工具步数。
    public let rounds: Int
    /// 耗时（秒）。
    public let duration: TimeInterval

    public init(caseId: String, passed: Bool, actualTools: [String], actualOutput: String, rounds: Int, duration: TimeInterval) {
        self.caseId = caseId
        self.passed = passed
        self.actualTools = actualTools
        self.actualOutput = actualOutput
        self.rounds = rounds
        self.duration = duration
    }

    public var jsonValue: JSONValue {
        .object([
            "caseId": .string(caseId),
            "passed": .bool(passed),
            "actualTools": .array(actualTools.map { .string($0) }),
            "actualOutput": .string(actualOutput),
            "rounds": .int(Int64(rounds)),
            "durationMs": .int(Int64((duration * 1000).rounded())),
        ])
    }
}

/// 一次评估的报告。
public struct EvalReport: Sendable, Equatable {
    /// 各用例结果。
    public let results: [EvalResult]

    public init(_ results: [EvalResult]) {
        self.results = results
    }

    /// 通过数。
    public var passedCount: Int {
        results.filter(\.passed).count
    }

    /// 通过率（无用例时为 0）。
    public var passRate: Double {
        results.isEmpty ? 0 : Double(passedCount) / Double(results.count)
    }

    /// 平均步数（无用例时为 0）。
    public var averageRounds: Double {
        guard !results.isEmpty else { return 0 }
        return Double(results.map(\.rounds).reduce(0, +)) / Double(results.count)
    }

    /// 与基线对比。
    public func compareTo(_ baseline: EvalReport) -> EvalDiff {
        EvalDiff(
            passRateDelta: passRate - baseline.passRate,
            averageRoundsDelta: averageRounds - baseline.averageRounds
        )
    }
}

/// 报告与基线的差异。
public struct EvalDiff: Sendable, Equatable {
    /// 通过率差。
    public let passRateDelta: Double
    /// 平均步数差。
    public let averageRoundsDelta: Double

    public init(passRateDelta: Double, averageRoundsDelta: Double) {
        self.passRateDelta = passRateDelta
        self.averageRoundsDelta = averageRoundsDelta
    }
}

extension EvalDiff: CustomStringConvertible {
    public var description: String {
        "通过率 \(signed(passRateDelta * 100))%，平均步数 \(signed(averageRoundsDelta))"
    }

    private func signed(_ value: Double) -> String {
        value >= 0 ? "+\(String(format: "%.1f", value))" : String(format: "%.1f", value)
    }
}

/// 默认判分（规格 S16 §6.6）：期望工具为实际工具子集、输出含关键词、步数不超限。
public func defaultEvalJudge(_ evalCase: EvalCase, _ result: EvalResult) -> Bool {
    let toolsOk = evalCase.expectedTools.allSatisfy(result.actualTools.contains)
    let outputOk = evalCase.expectedOutput.map { result.actualOutput.contains($0) } ?? true
    let roundsOk = evalCase.maxRounds.map { result.rounds <= $0 } ?? true
    return toolsOk && outputOk && roundsOk
}

/// 跑一条 case，返回该轮的 AgentTurn。
public typealias EvalRunner = (String) async throws -> AgentTurn

/// 评估器：跑 case、判分、汇总。
@ContextTreeActor
public final class Evaluator {
    /// 执行一条 case 的运行器（注入以便测试与替换）。
    public let run: EvalRunner
    /// 判分函数。
    public let judge: EvalJudge

    public init(run: @escaping EvalRunner, judge: @escaping EvalJudge = defaultEvalJudge) {
        self.run = run
        self.judge = judge
    }

    /// 跑一条 case。
    public func evaluate(_ evalCase: EvalCase) async throws -> EvalResult {
        let start = ContinuousClock.now
        let turn = try await run(evalCase.input)
        let duration = ContinuousClock.now - start
        let measured = EvalResult(
            caseId: evalCase.id,
            passed: false,
            actualTools: turn.steps.map { $0.call.name },
            actualOutput: turn.reply,
            rounds: turn.steps.count,
            duration: TimeInterval(duration.components.seconds) + TimeInterval(duration.components.attoseconds) / 1e18
        )
        return EvalResult(
            caseId: measured.caseId,
            passed: judge(evalCase, measured),
            actualTools: measured.actualTools,
            actualOutput: measured.actualOutput,
            rounds: measured.rounds,
            duration: measured.duration
        )
    }

    /// 跑一批 case，汇总为报告。
    public func runAll(_ cases: [EvalCase]) async throws -> EvalReport {
        var results: [EvalResult] = []
        for evalCase in cases {
            results.append(try await evaluate(evalCase))
        }
        return EvalReport(results)
    }
}
