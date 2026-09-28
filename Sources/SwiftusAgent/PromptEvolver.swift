import Foundation
import SwiftusCore
import SwiftusFoundation

/// 演化决策（规格 S16 §10.1）。
public enum EvolutionDecision: String, Sendable, Equatable {
    /// 晋升：替换当前 prompt。
    case promote
    /// 拒绝：丢弃变体。
    case reject
    /// 需要更多数据：样本不足。
    case insufficient
}

/// 演化结果。
public struct EvolutionResult: Sendable, Equatable {
    /// 演化决策。
    public let decision: EvolutionDecision
    /// 参与评估的变体（携带评估得分）。
    public let variant: PromptVariant
    /// 当前 prompt 的通过率。
    public let baselineScore: Double
    /// 变体 prompt 的通过率。
    public let variantScore: Double
    /// 通过率差（变体减基线）。
    public let improvement: Double

    public init(decision: EvolutionDecision, variant: PromptVariant, baselineScore: Double, variantScore: Double, improvement: Double) {
        self.decision = decision
        self.variant = variant
        self.baselineScore = baselineScore
        self.variantScore = variantScore
        self.improvement = improvement
    }
}

/// 提示词进化器（规格 S16 §10.1，服务键 'promptEvolver'）。
@ContextTreeActor
public protocol PromptEvolver: Sendable {
    /// 分析低质量轨迹，生成 prompt 候选。轨迹数不足 minTraces 时返回 nil。
    func propose(sectionName: String, lowQualityTraces: [SessionEvent]) async throws -> PromptVariant?

    /// 用 evaluation 对比变体与当前 prompt。
    func evaluate(_ variant: PromptVariant) async throws -> EvolutionResult

    /// 晋升：替换当前 prompt。需要人类确认。
    func promote(_ variant: PromptVariant, threshold: Double) async throws -> Bool

    /// 回滚到指定版本。
    func rollback(_ variantId: String) async throws

    /// 当前版本（最近晋升或回滚的变体）。
    var current: PromptVariant? { get }

    /// 历史版本（按创建时间升序）。
    var history: [PromptVariant] { get }
}

/// 'promptEvolver' 服务键。
extension ServiceKey where Service == any PromptEvolver {
    public static let promptEvolver = ServiceKey<any PromptEvolver>("promptEvolver")
}
