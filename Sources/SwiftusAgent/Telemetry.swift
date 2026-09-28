import Foundation
import os
import SwiftusCore

/// 一条遥测事件（规格 S16 §6.1）。
public struct TelemetryEvent: Sendable, Equatable {
    /// 事件名（如 tool.called / llm.request / agent.round）。
    public let name: String
    /// 事件负载。
    public let data: [String: JSONValue]
    /// 事件时间。
    public let time: Date

    public init(_ name: String, data: [String: JSONValue] = [:], time: Date = Date()) {
        self.name = name
        self.data = data
        self.time = time
    }

    /// 序列化为 JSONValue（name / time ISO8601 在前，负载展开在后）。
    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "time": .string(time.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))),
        ]
        for (key, value) in data {
            object[key] = value
        }
        return .object(object)
    }
}

/// 遥测导出端口（规格 S16 §6.1）。
public protocol Telemetry: Sendable {
    /// 记录一条事件。
    func emit(_ event: TelemetryEvent)

    /// 事件流（供评估/监控订阅；每次访问生成一个新订阅）。
    var events: AsyncStream<TelemetryEvent> { get }
}

/// 内存导出器：保留最近 limit 条并广播（规格 S16 §6.1）。
///
/// 状态全在锁盒里（非 actor）：遥测是跨域调用面，锁盒保证 Sendable 而不占用
/// ContextTreeActor。
public final class InMemoryTelemetry: Telemetry {
    /// 保留条数上限。
    public let limit: Int

    private struct State {
        var recent: [TelemetryEvent] = []
        var subscribers: [UUID: AsyncStream<TelemetryEvent>.Continuation] = [:]
        var closed = false
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// limit 为负时快速失败。
    public init(limit: Int = 1000) throws {
        guard limit >= 0 else {
            throw TelemetryError.negativeLimit(limit)
        }
        self.limit = limit
    }

    /// 最近记录的事件。
    public var recent: [TelemetryEvent] {
        state.withLock { $0.recent }
    }

    public var events: AsyncStream<TelemetryEvent> {
        AsyncStream { continuation in
            let token = UUID()
            state.withLock { current -> Void in
                if current.closed {
                    continuation.finish()
                    return
                }
                current.subscribers[token] = continuation
            }
            continuation.onTermination = { [state] _ in
                state.withLock { current -> Void in
                    current.subscribers.removeValue(forKey: token)
                }
            }
        }
    }

    public func emit(_ event: TelemetryEvent) {
        state.withLock { current in
            current.recent.append(event)
            if current.recent.count > limit {
                current.recent.removeFirst(current.recent.count - limit)
            }
            guard !current.closed else { return }
            for subscriber in current.subscribers.values {
                subscriber.yield(event)
            }
        }
    }

    /// 关闭广播流。幂等。
    public func close() {
        let subscribers: [AsyncStream<TelemetryEvent>.Continuation] = state.withLock { current in
            guard !current.closed else { return [] }
            current.closed = true
            let alive = Array(current.subscribers.values)
            current.subscribers.removeAll()
            return alive
        }
            // 锁内只取出订阅者、锁外再 finish：finish() 会同步触发 onTermination，
            // 而 onTermination 要再进同一把锁（OSAllocatedUnfairLock 不可重入）。
        for subscriber in subscribers {
            subscriber.finish()
        }
    }
}

/// 遥测配置错误。
public enum TelemetryError: Error, Equatable {
    /// limit 为负。
    case negativeLimit(Int)
}

/// 控制台导出器：`[name] {json}` 一行一条。
public final class ConsoleTelemetry: Telemetry {
    private let writer: @Sendable (String) -> Void

    public init(writer: (@Sendable (String) -> Void)? = nil) {
        self.writer = writer ?? { print($0) }
    }

    public var events: AsyncStream<TelemetryEvent> {
        AsyncStream { $0.finish() }
    }

    public func emit(_ event: TelemetryEvent) {
        let data = (try? JSONValue.object(event.data).jsonData()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        writer("[\(event.name)] \(data)")
    }
}

/// 'telemetry' 服务键。
extension ServiceKey where Service == any Telemetry {
    public static let telemetry = ServiceKey<any Telemetry>("telemetry")
}

/// 把 Telemetry 作为 'telemetry' 服务提供到上下文；缺省 InMemoryTelemetry
///（随上下文释放而 close）。
@ContextTreeActor
@discardableResult
public func provideTelemetry(_ ctx: Context, telemetry: (any Telemetry)? = nil) throws -> any Telemetry {
    let resolved = try telemetry ?? InMemoryTelemetry()
    try ctx.provide(.telemetry, resolved)
    if let memory = resolved as? InMemoryTelemetry {
        ctx.onDispose { memory.close() }
    }
    return resolved
}
