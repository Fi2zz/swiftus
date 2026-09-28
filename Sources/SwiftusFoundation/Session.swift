import Foundation
import SwiftusCore

/// 会话错误（规格 S3 §3；Dart StateError / ArgumentError 的结构化对应物）。
public enum SessionError: Error, Equatable {
    /// 会话关闭后仍追加事件。
    case sessionClosed(id: String)
    /// fork 找不到指定事件（sessionId 恒为原会话 id，见 S3 §8 有意偏离）。
    case eventNotFound(sessionId: String, eventId: String)
    /// inheritedEventCount 越界（必须落在 seed 范围内）。
    case invalidInheritedCount
}

/// 一次会话：append-only 事件日志（规格 S3 §3）。
///
/// 日志只追加、不改写；任何派生都是新事件 / 新会话（fork 产新会话）。
/// 追加同步通知 `onEvent` 监听器；关闭通知 `onClose` 并拒绝后续追加。
@ContextTreeActor
public final class Session {
    /// 会话标识（也是持久化文件名）。
    public let id: String

    /// 由 seed 继承的父会话事件条数（fork 时大于 0；重新打开会话时为 0）。
    public let inheritedEventCount: Int

    /// 会话创建时间（取首条事件时间；空日志为构造时刻）。
    public let createdAt: Date

    private var storedEvents: [SessionEvent]
    private var eventListeners: [UUID: @ContextTreeActor (SessionEvent) -> Void] = [:]
    private var closeListeners: [UUID: @ContextTreeActor () -> Void] = [:]
    private var nextSeq: Int
    private var forkCount = 0

    /// 是否已关闭。
    public private(set) var closed = false

    /// 构造会话；`inheritedEventCount` 必须落在 seed 范围内，否则抛 `SessionError.invalidInheritedCount`。
    public init(id: String, seed: [SessionEvent] = [], inheritedEventCount: Int = 0) throws {
        guard inheritedEventCount >= 0, inheritedEventCount <= seed.count else {
            throw SessionError.invalidInheritedCount
        }
        self.id = id
        self.inheritedEventCount = inheritedEventCount
        storedEvents = seed
        nextSeq = (seed.last?.seq ?? -1) + 1
        createdAt = seed.first?.time ?? Date()
    }

    /// 事件日志的只读视图。
    public var events: [SessionEvent] {
        storedEvents
    }

    /// 本会话自身拥有的事件（跳过继承前缀）。
    public var ownEvents: [SessionEvent] {
        Array(storedEvents.dropFirst(inheritedEventCount))
    }

    /// 事件条数。
    public var length: Int {
        storedEvents.count
    }

    /// 最后一条事件的 id；空日志为 nil。
    public var lastEventId: String? {
        storedEvents.last?.id
    }

    /// 追加一条事件并返回它。会话关闭后抛 `SessionError.sessionClosed`。
    @discardableResult
    public func append(
        _ type: String,
        data: JSONValue? = nil,
        parentEventId: String? = nil,
        time: Date? = nil,
        id eventId: String? = nil
    ) throws -> SessionEvent {
        guard !closed else { throw SessionError.sessionClosed(id: id) }
        let event = SessionEvent(
            seq: nextSeq,
            type: type,
            time: time ?? Date(),
            data: data,
            id: eventId ?? SessionEventIds.next(),
            sessionId: id,
            parentEventId: parentEventId
        )
        nextSeq += 1
        broadcast(event)
        return event
    }

    /// 追加一条已构造的事件：用本会话 id 与下一个 seq 重新盖章（time 保留原值，
    /// id 缺省重新生成），返回落定后的事件（规格 S3 §3.2）。
    @discardableResult
    public func appendEvent(_ event: SessionEvent) throws -> SessionEvent {
        guard !closed else { throw SessionError.sessionClosed(id: id) }
        var stamped = event
        stamped.sessionId = id
        stamped.seq = nextSeq
        stamped.id = stamped.id ?? SessionEventIds.next()
        nextSeq += 1
        broadcast(stamped)
        return stamped
    }

    /// 按时间（seq）顺序读取事件；`from` / `to` 为闭区间的时间过滤。
    public func read(from: Date? = nil, to: Date? = nil) -> [SessionEvent] {
        storedEvents.filter { event in
            if let from, event.time < from { return false }
            if let to, event.time > to { return false }
            return true
        }
    }

    /// 从 `fromEventId` 处 fork 出新会话（规格 S3 §3.6）。找不到该事件时抛
    /// `SessionError.eventNotFound`；原会话不受影响。
    public func fork(fromEventId: String? = nil, id newId: String? = nil) throws -> Session {
        let seed: [SessionEvent]
        if let fromEventId {
            guard let index = storedEvents.firstIndex(where: { $0.id == fromEventId }) else {
                throw SessionError.eventNotFound(sessionId: id, eventId: fromEventId)
            }
            seed = Array(storedEvents[...index])
        } else {
            seed = storedEvents
        }
        forkCount += 1
        return try Session(
            id: newId ?? "\(id)-fork-\(forkCount)",
            seed: seed,
            inheritedEventCount: seed.count
        )
    }

    /// 重放：按事件顺序依次回调 handler（基于快照）。日志不被改写。
    public func replay(_ handler: @ContextTreeActor (SessionEvent) -> Void) {
        for event in storedEvents {
            handler(event)
        }
    }

    /// 监听后续追加。返回幂等 Disposer。
    @discardableResult
    public func onEvent(_ listener: @escaping @ContextTreeActor (SessionEvent) -> Void) -> Disposer {
        let token = UUID()
        eventListeners[token] = listener
        return { [weak self] in
            self?.eventListeners.removeValue(forKey: token)
        }
    }

    /// 监听会话关闭；已关闭时立即回调。返回幂等 Disposer。
    @discardableResult
    public func onClose(_ listener: @escaping @ContextTreeActor () -> Void) -> Disposer {
        guard !closed else {
            listener()
            return {}
        }
        let token = UUID()
        closeListeners[token] = listener
        return { [weak self] in
            self?.closeListeners.removeValue(forKey: token)
        }
    }

    /// 关闭会话：通知关闭监听器并拒绝后续追加。幂等。
    public func close() {
        guard !closed else { return }
        closed = true
        let listeners = Array(closeListeners.values)
        closeListeners.removeAll()
        eventListeners.removeAll()
        for listener in listeners {
            listener()
        }
    }

    private func broadcast(_ event: SessionEvent) {
        storedEvents.append(event)
        for listener in Array(eventListeners.values) {
            listener(event)
        }
    }
}
