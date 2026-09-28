import SwiftusCompaction
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 'agentLoop' 服务键。
extension ServiceKey where Service == AgentLoop {
    public static let agentLoop = ServiceKey<AgentLoop>("agentLoop")
}

/// 把 AgentLoop 作为 'agentLoop' 服务提供到上下文（规格 S4 §6.3）。
///
/// 依赖 'llm' 与 'tools'；'systemPrompt' / 'compaction' 存在时自动接入。
/// 未显式传 session 时，若恰好只有一个打开的会话则用它。
/// 'sessionLogRecorder' 存在且有会话时：接管镜像、模型调用记录（SessionLogLlmProvider
/// 装饰）与工具调用埋点，随上下文释放撤销。
@ContextTreeActor
@discardableResult
public func provideAgentLoop(
    _ ctx: Context,
    session: Session? = nil,
    maxSteps: Int = 8,
    onStream: (@ContextTreeActor (LlmStreamEvent) -> Void)? = nil
) throws -> AgentLoop {
    let llm = try ctx.require(.llm)
    let tools = try ctx.require(.tools)
    let recorder = ctx.get(.sessionLogRecorder)
    var config = AgentLoop.Config()
    config.session = session ?? soleOpenSession(ctx)
    config.systemPrompt = ctx.get(.systemPrompt)
    config.compactor = ctx.get(.compaction)
    config.maxSteps = maxSteps
    config.onStream = onStream
    let effectiveLlm: any LlmProvider
    if let recorder {
        effectiveLlm = SessionLogLlmProvider(llm, recorder: recorder)
    } else {
        effectiveLlm = llm
    }
    let loop = AgentLoop(llm: effectiveLlm, tools: tools, config: config)
    if let recorder, let target = config.session {
        ctx.effect { recorder.attach(target) }
        ctx.effect { instrumentSessionLogTools(tools, recorder: recorder) }
    }
    try ctx.provide(.agentLoop, loop)
    return loop
}

/// 恰好一个打开会话时返回它，否则 nil。
@ContextTreeActor
private func soleOpenSession(_ ctx: Context) -> Session? {
    guard let store = ctx.get(.sessions), store.length == 1 else { return nil }
    return store.get(store.ids[0])
}
