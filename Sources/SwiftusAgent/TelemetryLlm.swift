import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 给任意 LlmProvider 加 llm.request / llm.failed 埋点的装饰器（规格 S16 §6.1）。
@ContextTreeActor
public final class TelemetryLlmProvider: LlmProvider {
    /// 被包装的 provider。
    public let inner: any LlmProvider
    /// 遥测导出器。
    public let telemetry: any Telemetry

    public init(_ inner: any LlmProvider, telemetry: any Telemetry) {
        self.inner = inner
        self.telemetry = telemetry
    }

    public var name: String {
        inner.name
    }

    public func chat(_ request: LlmRequest) async throws -> LlmResult {
        let start = ContinuousClock.now
        do {
            let result = try await inner.chat(request)
            telemetry.emit(TelemetryEvent("llm.request", data: [
                "provider": .string(inner.name),
                "model": .string(result.model),
                "ms": .int(Int64(milliseconds(from: start))),
                "messages": .int(Int64(request.messages.count)),
                "tools": .int(Int64(request.tools?.count ?? 0)),
                "toolCalls": .int(Int64(result.toolCalls.count)),
            ]))
            return result
        } catch {
            telemetry.emit(TelemetryEvent("llm.failed", data: [
                "provider": .string(inner.name),
                "ms": .int(Int64(milliseconds(from: start))),
                "error": .string("\(error)"),
            ]))
            throw error
        }
    }

    public func chatStream(_ request: LlmRequest) -> AsyncThrowingStream<LlmStreamEvent, any Error> {
        inner.chatStream(request)
    }

    public func close() {
        inner.close()
    }
}

/// 起点到当前的毫秒数。
func milliseconds(from start: ContinuousClock.Instant) -> Int {
    let elapsed = ContinuousClock.now - start
    return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
}

/// 在工具表上挂埋点中间件（tool.called / tool.failed），返回撤销函数
///（规格 S16 §6.1：失败时额外发 tool.failed，两条路径各自只发一次）。
@ContextTreeActor
@discardableResult
public func instrumentTools(
    _ ctx: Context,
    telemetry: (any Telemetry)? = nil,
    tools: ToolRegistry? = nil
) throws -> Disposer {
    let sink = try telemetry ?? ctx.require(.telemetry)
    let registry = try tools ?? ctx.require(.tools)
    return ctx.effect {
        let token = registry.use { call, next in
            let start = ContinuousClock.now
            do {
                let result = try await next()
                sink.emit(TelemetryEvent("tool.called", data: [
                    "tool": .string(call.name),
                    "isError": .bool(result.failed),
                    "ms": .int(Int64(milliseconds(from: start))),
                    "args": .object(call.arguments),
                ]))
                if result.failed {
                    sink.emit(TelemetryEvent("tool.failed", data: [
                        "tool": .string(call.name),
                        "ms": .int(Int64(milliseconds(from: start))),
                        "error": .string(result.error?.message ?? result.content),
                    ]))
                }
                return result
            } catch {
                sink.emit(TelemetryEvent("tool.failed", data: [
                    "tool": .string(call.name),
                    "ms": .int(Int64(milliseconds(from: start))),
                    "error": .string("\(error)"),
                ]))
                throw error
            }
        }
        let disposer: Disposer = {
            registry.removePipelineListener(token)
        }
        return disposer
    }
}
