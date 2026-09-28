import Foundation
import SwiftusCore
import SwiftusFoundation

/// 当前快照 schema 版本（规格 S16 §6.4）。
public let kSnapshotVersion = 1

/// 快照相关错误（code: not-found / unsupported-version）。
public struct RecoveryError: Error, Equatable {
    /// 机器可读错误码。
    public let code: String
    /// 人可读说明。
    public let message: String

    public static func notFound(_ sessionId: String) -> RecoveryError {
        RecoveryError(code: "not-found", message: "没有会话 \"\(sessionId)\" 的快照")
    }

    public static func unsupportedVersion(_ version: Int) -> RecoveryError {
        RecoveryError(
            code: "unsupported-version",
            message: "快照版本 \(version) 不受支持（当前 \(kSnapshotVersion)）"
        )
    }
}

extension RecoveryError: CustomStringConvertible {
    public var description: String {
        "RecoveryError(\(code)): \(message)"
    }
}

/// 一次会话快照（规格 S16 §6.4）：事件日志 + 版本 + 时间。
///
/// 计划以 plan/updated 事件存在，故一并被快照；长期记忆由 MemoryStore 自己的
/// 后端持久化（W3）。
public struct SessionSnapshot: Sendable, Equatable {
    /// 会话 id。
    public let sessionId: String
    /// 全部事件。
    public let events: [SessionEvent]
    /// 快照时间。
    public let savedAt: Date?
    /// schema 版本。
    public let version: Int

    public init(sessionId: String, events: [SessionEvent], savedAt: Date? = nil, version: Int = kSnapshotVersion) {
        self.sessionId = sessionId
        self.events = events
        self.savedAt = savedAt
        self.version = version
    }

    /// 从 JSONValue 反序列化；版本不符抛 RecoveryError.unsupportedVersion。
    public init(jsonValue: JSONValue) throws {
        let object = jsonValue.objectValue ?? [:]
        let version = object["version"]?.intValue ?? 0
        guard version == kSnapshotVersion else {
            throw RecoveryError.unsupportedVersion(version)
        }
        sessionId = object["sessionId"]?.stringValue ?? ""
        events = (object["events"]?.arrayValue ?? []).map(SessionEvent.init(jsonValue:))
        savedAt = object["savedAt"]?.stringValue.flatMap { try? Date($0, strategy: .iso8601) }
        self.version = version
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "version": .int(Int64(version)),
            "sessionId": .string(sessionId),
            "events": .array(events.map(\.jsonValue)),
        ]
        if let savedAt {
            object["savedAt"] = .string(savedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return .object(object)
    }
}

/// 快照存储端口（规格 S16 §6.4）。
public protocol SnapshotStore: Sendable {
    /// 保存（覆盖）一份快照。
    func save(_ snapshot: SessionSnapshot) async throws

    /// 载入快照；不存在返回 nil。
    func load(_ sessionId: String) async throws -> SessionSnapshot?

    /// 已保存的会话 id。
    func list() async throws -> [String]

    /// 删除快照。
    func delete(_ sessionId: String) async throws
}

/// 内存实现（测试用）。
@ContextTreeActor
public final class MemorySnapshotStore: SnapshotStore {
    private var snapshots: [String: SessionSnapshot] = [:]

    public init() {}

    public func save(_ snapshot: SessionSnapshot) async {
        snapshots[snapshot.sessionId] = snapshot
    }

    public func load(_ sessionId: String) async -> SessionSnapshot? {
        snapshots[sessionId]
    }

    public func list() async -> [String] {
        Array(snapshots.keys)
    }

    public func delete(_ sessionId: String) async {
        snapshots.removeValue(forKey: sessionId)
    }
}
