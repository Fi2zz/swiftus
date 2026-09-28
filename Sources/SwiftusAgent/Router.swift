import SwiftusCore
import SwiftusLLM

/// 一次路由决策（规格 S16 §3）。
public enum RouteDecision: Sendable, Equatable {
    /// 本地直答：直接作为回复收口，不调模型。
    case reply(String)
    /// 预置工具调用：先执行，再让模型据此收口。
    case tools([LlmToolCall])
    /// 未命中：落回模型决策。
    case pass
}

/// 确定性路由器（规格 S16 §3，服务键 'router'）：命中即走快路径，未命中落模型。
@ContextTreeActor
public protocol Router: Sendable {
    /// 对一轮用户输入做路由判断。
    func route(_ input: String) async throws -> RouteDecision
}

/// 'router' 服务键。
extension ServiceKey where Service == any Router {
    public static let router = ServiceKey<any Router>("router")
}

/// 将 Router 作为 'router' 服务提供到上下文。
@ContextTreeActor
@discardableResult
public func provideRouter(_ ctx: Context, _ router: any Router) throws -> any Router {
    try ctx.provide(.router, router)
    return router
}
