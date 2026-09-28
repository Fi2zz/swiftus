import Foundation
import SwiftusCore

/// 本地 JSON 文件凭据来源（规格 S12 §7.2）：只读，可定时刷新。
///
/// 两种形态都支持：
/// ```json
/// { "ARK_API_KEY": "sk-xxx" }
/// { "ARK_API_KEY": { "value": "sk-xxx", "expiresAt": "2026-01-01T00:00:00Z" } }
/// ```
///
/// 构造后需显式 `load()`（或 `refresh()`，二者等价）把文件读进快照；文件不存在
/// 时用 `fallback` 兜底。内容不是合法 JSON 时 `load` 抛 `invalid-source`。
@ContextTreeActor
public final class FileCredentials: Credentials {
    /// 读 `path` 处的 JSON 文件；`fallback` 是文件缺失时的兜底值。
    public let path: String
    private let fallback: [String: Credential]
    private let snapshot = CredentialSnapshot()
    private let scheduler: RefreshScheduler

    public init(
        path: String,
        fallback: [String: String] = [:],
        refreshInterval: TimeInterval? = nil,
        clock: any RefreshClock = TaskRefreshClock()
    ) {
        self.path = path
        self.fallback = fallback.reduce(into: [:]) { table, entry in
            table[entry.key] = Credential(key: entry.key, value: entry.value)
        }
        scheduler = RefreshScheduler(interval: refreshInterval, clock: clock)
    }

    public var keys: [String] {
        snapshot.keys
    }

    public func get(_ key: String) -> Credential? {
        snapshot.get(key)
    }

    public func update(_ key: String, _ value: String) async throws {
        throw CredentialsException(.readOnly, "文件凭据是只读来源。")
    }

    /// 读文件入快照；文件不存在时退回 `fallback`。之后按需续上定时刷新。
    public func load() async throws {
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            guard let data = text.data(using: .utf8) else {
                throw CredentialsException(.invalidSource, "凭据文件不是合法 JSON：\(path)")
            }
            guard let json = try? JSONValue.parse(data) else {
                throw CredentialsException(.invalidSource, "凭据文件不是合法 JSON：\(path)")
            }
            snapshot.refreshSnapshot(parseCredentialMap(json))
        } else {
            snapshot.refreshSnapshot(fallback)
        }
        scheduler.schedule { [weak self] in
            try? await self?.load()
        }
    }

    public func refresh() async throws {
        try await load()
    }

    @discardableResult
    public func addChangeListener(_ body: @escaping @ContextTreeActor (Credential) -> Void) -> Int {
        snapshot.addChangeListener(body)
    }

    @discardableResult
    public func removeChangeListener(_ token: Int) -> Bool {
        snapshot.removeChangeListener(token)
    }

    public func close() {
        scheduler.cancel()
        snapshot.close()
    }
}
