import Foundation
import os
import SwiftusCore
import SwiftusFoundation

/// goal 的四个能力缝及其使用点（规格 S16 §7.3）。
///
/// 集中解析 session / systemPrompt / approval / telemetry 四个可选依赖
///（显式传入优先，缺省从 Context 惰性解析，再缺省降级）。
@ContextTreeActor
final class GoalSeams {
    private let context: Context?
    private var session: Session?
    private var prompt: SystemPrompt?
    private var approval: (any Approval)?
    private var telemetry: (any Telemetry)?
    private var sectionDisposer: Disposer?

    init(
        session: Session? = nil,
        prompt: SystemPrompt? = nil,
        approval: (any Approval)? = nil,
        telemetry: (any Telemetry)? = nil,
        ctx: Context? = nil
    ) {
        self.session = session
        self.prompt = prompt
        self.approval = approval
        self.telemetry = telemetry
        context = ctx
    }

    /// 解析 session（Swift 侧 Session 非上下文服务，仅显式传入；对齐 Dart 的
    /// 「显式 > 上下文」中显式分支，上下文分支无对应物）。
    func resolveSession() -> Session? {
        session
    }

    /// 显式绑定 session（restore 用）；之后 resolveSession 优先返回它。
    func bindSession(_ session: Session) {
        self.session = session
    }

    /// 追加一条 goal/changed 事件（整值替换）。
    func appendEvent(_ goal: Goal) {
        _ = try? resolveSession()?.append(kGoalEvent, data: goal.jsonValue)
    }

    /// 发出一个 goal.* 埋点事件。
    func emit(_ eventName: String, _ goal: Goal) {
        resolveTelemetry()?.emit(TelemetryEvent(eventName, data: [
            "id": .string(goal.id),
            "status": .string(goal.status.rawValue),
        ]))
    }

    /// 经 approval 确认动作；gate 不可用自动批准，拒绝抛 GoalException。
    func confirm(_ toolName: String, _ description: String, _ goal: Goal) async throws {
        guard let gate = resolveApproval() else { return }
        let ok = await gate.request(ApprovalRequest(
            id: "\(toolName)-\(Int(Date().timeIntervalSince1970 * 1_000_000))",
            toolName: toolName,
            arguments: goal.jsonValue.objectValue ?? [:],
            description: description
        ))
        guard ok else {
            throw GoalException("cancelled", "用户取消")
        }
    }

    /// 按 current 的最新值同步 goal 段：有目标时注入（order 50），无目标时撤销。
    func syncSection(_ current: @escaping @ContextTreeActor () -> Goal?) {
        guard current() != nil else {
            detachSection()
            return
        }
        guard sectionDisposer == nil else { return }
        guard let prompt = resolvePrompt() else { return }
        sectionDisposer = try? prompt.section(PromptSection(name: "goal", order: 50, text: {
            Self.sectionText(current)
        }))
    }

    /// goal 段文本；无目标时为空串。
    static func sectionText(_ current: @escaping @ContextTreeActor () -> Goal?) -> String {
        guard let goal = current() else { return "" }
        let progress = goal.round > 0 ? "\n进度：第 \(goal.round) / \(goal.maxRounds) 轮" : ""
        return "[当前目标]\n\(goal.text)\(progress)"
    }

    /// 撤销 goal 段（幂等）。
    func detachSection() {
        if let disposer = sectionDisposer {
            try? disposer()
        }
        sectionDisposer = nil
    }

    private func resolvePrompt() -> SystemPrompt? {
        if let prompt { return prompt }
        let resolved = context?.get(.systemPrompt)
        prompt = resolved
        return resolved
    }

    private func resolveApproval() -> (any Approval)? {
        if let approval { return approval }
        let resolved = context?.get(.approval)
        approval = resolved
        return resolved
    }

    private func resolveTelemetry() -> (any Telemetry)? {
        if let telemetry { return telemetry }
        let resolved = context?.get(.telemetry)
        telemetry = resolved
        return resolved
    }
}
