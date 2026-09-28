import Foundation
import SwiftusCore
import SwiftusFoundation

/// 在工具表上挂审批中间件（规格 S16 §6.2）：对风险不低于 threshold 的工具，
/// 先经 Approval 批准再执行；拒绝或超时返回 APPROVAL_DENIED 失败结果。
///
/// 工具用 Tool.pathParams 声明路径参数时，中间件把它们的取值交给
/// Approval.preapproved：已获信任的调用直接放行。声明路径参数的**低风险**工具
/// 同样进入审批——「读文件也要按目录授权」的落点。
@ContextTreeActor
@discardableResult
public func instrumentApproval(
    _ ctx: Context,
    approval: (any Approval)? = nil,
    tools: ToolRegistry? = nil,
    telemetry: (any Telemetry)? = nil,
    threshold: ToolRisk = .high,
    timeout: TimeInterval = 300
) throws -> Disposer {
    let gate = try approval ?? ctx.require(.approval)
    let registry = try tools ?? ctx.require(.tools)
    let sink = telemetry ?? ctx.get(.telemetry)
    return ctx.effect {
        let token = registry.use { call, next in
            guard let tool = registry.get(call.name) else {
                return try await next()
            }
            let paths = pathArguments(tool, call)
            let gated = tool.riskLevel >= threshold || !paths.isEmpty
            guard gated else {
                return try await next()
            }
            let request = ApprovalRequest(
                id: "approval-\(Int(Date().timeIntervalSince1970 * 1_000_000))",
                toolName: call.name,
                arguments: call.arguments,
                description: tool.description,
                pathArgs: paths
            )
            if !paths.isEmpty, await gate.preapproved(request) {
                return try await next()
            }
            sink?.emit(TelemetryEvent("approval.requested", data: [
                "tool": .string(call.name),
                "risk": .string(tool.riskLevel.label),
            ]))
            let approved = try await raceTimeout(seconds: timeout) {
                await gate.request(request)
            }
            sink?.emit(TelemetryEvent("approval.decided", data: [
                "tool": .string(call.name),
                "approved": .bool(approved),
            ]))
            guard approved else {
                return .failure(
                    "用户拒绝执行 \"\(call.name)\"",
                    error: ToolError("APPROVAL_DENIED", "approval denied")
                )
            }
            return try await next()
        }
        let disposer: Disposer = {
            registry.removePipelineListener(token)
        }
        return disposer
    }
}

/// 取出工具声明的路径参数取值（非空字符串；支持 `a.b` 形式的嵌套取值）。
@ContextTreeActor
public func pathArguments(_ tool: any Tool, _ call: ToolCall) -> [String] {
    let declared = tool.pathParams
    guard !declared.isEmpty else { return [] }
    var values: [String] = []
    for key in declared {
        let raw = lookup(call.arguments, key: key)
        let value = stringify(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            values.append(value)
        }
    }
    return values
}

/// 路径参数的嵌套取值（`a.b` 先取 a 对象再取 b）。
private func lookup(_ args: [String: JSONValue], key: String) -> JSONValue? {
    let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return args[key] }
    guard case let .object(nested) = args[parts[0]] else { return nil }
    return nested[parts[1]]
}

/// JSONValue 的展示串（Dart `'$raw'` 插值的近义：标量直取，复合形状取 JSON 文本）。
private func stringify(_ value: JSONValue?) -> String {
    if case let .string(text) = value { return text }
    if value == nil || value == .null { return "" }
    if let data = try? value?.jsonData() { return String(decoding: data, as: UTF8.self) }
    return ""
}

/// 'approval' 服务键。
extension ServiceKey where Service == any Approval {
    public static let approval = ServiceKey<any Approval>("approval")
}

/// 提供 'approval' 服务并安装审批拦截，返回审批端口（规格 S16 §6.2）。
///
/// 默认 AutoApproval 拒绝（安全优先）；instrument 为 false 时只提供服务、不挂
/// 拦截（适合拦截阈值由别处动态决定的装配方，自行调用 instrumentApproval）。
@ContextTreeActor
@discardableResult
public func provideApproval(
    _ ctx: Context,
    approval: (any Approval)? = nil,
    tools: ToolRegistry? = nil,
    threshold: ToolRisk = .high,
    timeout: TimeInterval = 300,
    instrument: Bool = true
) throws -> any Approval {
    let gate = approval ?? AutoApproval(false)
    try ctx.provide(.approval, gate)
    if instrument {
        try instrumentApproval(ctx, approval: gate, tools: tools, threshold: threshold, timeout: timeout)
    }
    ctx.onDispose { gate.close() }
    return gate
}
