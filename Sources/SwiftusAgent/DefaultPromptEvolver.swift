import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 默认提示词进化器（规格 S16 §10.2）：失败分析 → 变体生成 → A/B 评估 →
/// 晋升/回滚。晋升前后各版本经 PromptStore 存档；A/B 评估期间临时替换 prompt
/// section，结束（含异常）后恢复。
@ContextTreeActor
public final class DefaultPromptEvolver: PromptEvolver {
    private let llm: any LlmProvider
    private let evaluator: Evaluator
    private let prompt: SystemPrompt
    private let evalCases: [EvalCase]
    private let approval: (any Approval)?
    private let telemetry: (any Telemetry)?
    private let store: PromptStore
    private let minTraces: Int
    private let maxBudgetPerRun: Int

    private var originals: [String: PromptSection] = [:]
    private var currentVariant: PromptVariant?

    public init(
        llm: any LlmProvider,
        evaluator: Evaluator,
        prompt: SystemPrompt,
        evalCases: [EvalCase] = [],
        approval: (any Approval)? = nil,
        telemetry: (any Telemetry)? = nil,
        store: PromptStore? = nil,
        minTraces: Int = 10,
        maxBudgetPerRun: Int = 50_000
    ) {
        self.llm = llm
        self.evaluator = evaluator
        self.prompt = prompt
        self.evalCases = evalCases
        self.approval = approval
        self.telemetry = telemetry
        self.store = store ?? PromptStore()
        self.minTraces = minTraces
        self.maxBudgetPerRun = maxBudgetPerRun
    }

    public var history: [PromptVariant] {
        store.all
    }

    public var current: PromptVariant? {
        currentVariant
    }

    /// 从存档恢复历史版本，并把最后一条作为当前版本。
    public func restore() async {
        await store.load()
        if let last = store.all.last {
            currentVariant = last
        }
    }

    public func propose(sectionName: String, lowQualityTraces: [SessionEvent]) async throws -> PromptVariant? {
        guard lowQualityTraces.count >= minTraces else { return nil }
        let patterns = try await analyzeFailurePatterns(llm, lowQualityTraces)
        let variant = try await generateVariant(
            llm: llm,
            prompt: prompt,
            sectionName: sectionName,
            failurePatterns: patterns,
            parentId: currentVariant?.id
        )
        telemetry?.emit(TelemetryEvent("prompt.proposed", data: [
            "section": .string(sectionName),
            "variant": .string(variant.id),
        ]))
        return variant
    }

    public func evaluate(_ variant: PromptVariant) async throws -> EvolutionResult {
        let cases = budgetedCases()
        let baseline = try await evaluator.runAll(cases)
        swapSection(variant.sectionName, text: variant.text)
        let variantReport: EvalReport
        do {
            variantReport = try await evaluator.runAll(cases)
        } catch {
            restoreSection(variant.sectionName)
            throw error
        }
        restoreSection(variant.sectionName)
        let improvement = variantReport.passRate - baseline.passRate
        return EvolutionResult(
            decision: decide(improvement),
            variant: variant.withScore(variantReport.passRate),
            baselineScore: baseline.passRate,
            variantScore: variantReport.passRate,
            improvement: improvement
        )
    }

    public func promote(_ variant: PromptVariant, threshold: Double = 0.05) async throws -> Bool {
        let result = try await evaluate(variant)
        let evaluated = result.variant
        guard result.improvement >= threshold else { return false }

        if let gate = approval {
            let approved = await gate.request(ApprovalRequest(
                id: "promote-\(Int(Date().timeIntervalSince1970 * 1_000_000))",
                toolName: "promote_prompt",
                arguments: [
                    "section": .string(evaluated.sectionName),
                    "improvement": .double(result.improvement),
                    "variant": .string(evaluated.id),
                ],
                description: "提示词改进 +\(String(format: "%.1f", result.improvement * 100))%，确认晋升？\n\(preview(evaluated.text))"
            ))
            guard approved else { return false }
        }

        try await archiveCurrent(evaluated.sectionName)
        swapSection(evaluated.sectionName, text: evaluated.text)
        await store.save(evaluated)
        currentVariant = evaluated
        telemetry?.emit(TelemetryEvent("prompt.promoted", data: [
            "variant": .string(evaluated.id),
            "improvement": .double(result.improvement),
        ]))
        return true
    }

    public func rollback(_ variantId: String) async throws {
        guard let target = store.find(variantId) else {
            throw PromptEvolverError.variantNotFound(variantId)
        }
        try await archiveCurrent(target.sectionName)
        swapSection(target.sectionName, text: target.text)
        await store.save(target)
        currentVariant = target
        telemetry?.emit(TelemetryEvent("prompt.rolled_back", data: [
            "variant": .string(target.id),
        ]))
    }

    private func archiveCurrent(_ sectionName: String) async throws {
        if let currentVariant {
            await store.save(currentVariant)
            return
        }
        let now = Date()
        await store.save(PromptVariant(
            id: "initial-\(Int(now.timeIntervalSince1970 * 1_000_000))",
            sectionName: sectionName,
            text: try sectionText(prompt, name: sectionName),
            reason: "初始版本",
            createdAt: now
        ))
    }

    private func swapSection(_ name: String, text: String) {
        guard let existing = findSection(name) else {
            return
        }
        originals[name] = existing
        _ = prompt.remove(name)
        _ = try? prompt.section(PromptSection(name: name, order: existing.order, text: { text }))
    }

    private func restoreSection(_ name: String) {
        guard let original = originals.removeValue(forKey: name) else { return }
        if findSection(name) != nil {
            _ = prompt.remove(name)
        }
        _ = try? prompt.section(original)
    }

    private func findSection(_ name: String) -> PromptSection? {
        prompt.sectionList.first { $0.name == name }
    }

    private func decide(_ improvement: Double) -> EvolutionDecision {
        if improvement > 0.05 { return .promote }
        if improvement < -0.02 { return .reject }
        return .insufficient
    }

    private func budgetedCases() -> [EvalCase] {
        var spent = 0
        return evalCases.filter { evalCase in
            spent += estimateTokens(evalCase.input)
            return spent <= maxBudgetPerRun
        }
    }

    private func preview(_ text: String) -> String {
        text.count > 200 ? String(text.prefix(200)) + "…" : text
    }
}

/// prompt-evolver 装配的输入（参数封装）。
public struct PromptEvolverConfig {
    /// 显式实例（优先）。
    public var evolver: (any PromptEvolver)?
    /// 模型（缺省取上下文 'llm'）。
    public var llm: (any LlmProvider)?
    /// 审批缝。
    public var approval: (any Approval)?
    /// 遥测。
    public var telemetry: (any Telemetry)?
    /// 触发分析的轨迹数下限。
    public var minTraces = 10
    /// 单次评估的 token 预算上限。
    public var maxBudgetPerRun = 50_000

    public init() {}
}

/// 提供 'promptEvolver' 服务（规格 S16 §10.2）。
///
/// evaluator / sessionLog / prompt 必需（显式传入）；evalCases 是 A/B 测试的
/// 固定用例集（缺省为空，此时 evaluate 得 insufficient）。llm 缺省取上下文
/// 'llm'，缺失时抛 PromptEvolverError.llmUnavailable。
@ContextTreeActor
@discardableResult
public func providePromptEvolver(
    _ ctx: Context,
    evaluator: Evaluator,
    sessionLog: any SessionLog,
    prompt: SystemPrompt,
    evalCases: [EvalCase] = [],
    config: PromptEvolverConfig = PromptEvolverConfig()
) throws -> any PromptEvolver {
    guard let model = config.llm ?? ctx.get(.llm) else {
        throw PromptEvolverError.llmUnavailable
    }
    let resolved: any PromptEvolver
    if let evolver = config.evolver {
        resolved = evolver
    } else {
        resolved = DefaultPromptEvolver(
            llm: model,
            evaluator: evaluator,
            prompt: prompt,
            evalCases: evalCases,
            approval: config.approval ?? ctx.get(.approval),
            telemetry: config.telemetry ?? ctx.get(.telemetry),
            minTraces: config.minTraces,
            maxBudgetPerRun: config.maxBudgetPerRun
        )
    }
    try ctx.provide(.promptEvolver, resolved)
    return resolved
}
