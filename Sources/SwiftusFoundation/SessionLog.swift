import Foundation

/// 多会话只追加日志的失败（规格 S4 §3）。
///
/// 实现注记：Dart 侧此处抛 ArgumentError / StateError；SessionLog 层归一为
/// SessionLogError（code 机器可读，message 与 Dart 文案对齐）。
public struct SessionLogError: Error, Equatable {
    /// 机器可读错误码。
    public let code: String
    /// 人类可读说明。
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// 多会话的只追加事件日志（规格 S4 §3，服务键 `sessionLog`）。
///
/// 只追加是硬不变式：日志永不改写，fork 只产生新会话，源会话不受影响。
public protocol SessionLog: Sendable {
    /// 追加一条事件，返回落定后的事件（seq 由日志按会话分配并覆盖入参）。
    @discardableResult
    func append(_ event: SessionEvent) async throws -> SessionEvent

    /// 按 seq 顺序读取某会话的事件；from / to 为 time 闭区间过滤。
    func read(_ sessionId: String, from: Date?, to: Date?) async throws -> [SessionEvent]

    /// 从 fromEventId（含）分叉出新会话，返回新会话 id；源会话不受影响。
    @discardableResult
    func fork(_ sessionId: String, fromEventId: String, newId: String?) async throws -> String

    /// 按 seq 顺序重放某会话的事件。日志不被改写。
    func replay(_ sessionId: String, handler: @Sendable (SessionEvent) -> Void) async throws

    /// 列出所有已有会话 id（升序）。
    func list() async throws -> [String]

    /// 释放后端资源。幂等。
    func close() async
}

extension SessionLog {
    /// 读某会话全部事件。
    public func read(_ sessionId: String) async throws -> [SessionEvent] {
        try await read(sessionId, from: nil, to: nil)
    }

    /// 分叉出新会话（自动生成 id）。
    @discardableResult
    public func fork(_ sessionId: String, fromEventId: String) async throws -> String {
        try await fork(sessionId, fromEventId: fromEventId, newId: nil)
    }
}

/// 校验并取出事件所属的会话 id；缺失时抛 SessionLogError（规格 S4 §3 append）。
public func requireEventSessionId(_ event: SessionEvent) throws -> String {
    guard let sessionId = event.sessionId, !sessionId.isEmpty else {
        throw SessionLogError(
            code: "invalid_event",
            message: "SessionLog 要求事件带非空 sessionId"
        )
    }
    return sessionId
}

/// 事件是否落在 from / to 的闭区间内。
public func eventInWindow(_ event: SessionEvent, from: Date?, to: Date?) -> Bool {
    if let from, event.time < from { return false }
    if let to, event.time > to { return false }
    return true
}

/// 取「截止 fromEventId（含）」的事件前缀；找不到时抛 SessionLogError。
public func eventPrefix(_ events: [SessionEvent], fromEventId: String) throws -> [SessionEvent] {
    guard let index = events.firstIndex(where: { $0.id == fromEventId }) else {
        throw SessionLogError(
            code: "event_not_found",
            message: "会话日志中不存在事件 \"\(fromEventId)\""
        )
    }
    return Array(events[...index])
}

/// 生成分叉会话的缺省 id，并前推 counters 里的会话计数。
public func nextForkId(_ sessionId: String, counters: inout [String: Int]) -> String {
    let count = (counters[sessionId] ?? 0) + 1
    counters[sessionId] = count
    return "\(sessionId)-fork-\(count)"
}

/// 为分叉前缀重新盖章：换成新会话 id，seq 从 0 起重新连续编号（规格 S4 §3 fork）。
/// 事件 id 与 parentEventId 原样保留，分叉会话与源会话共享的前缀仍可逐条对齐。
public func restampPrefix(_ prefix: [SessionEvent], newSessionId: String) -> [SessionEvent] {
    prefix.enumerated().map { index, event in
        var stamped = event
        stamped.seq = index
        stamped.sessionId = newSessionId
        return stamped
    }
}
