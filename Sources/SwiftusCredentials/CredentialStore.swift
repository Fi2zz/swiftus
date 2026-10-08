import Foundation
import SwiftusCore

/// 可插拔凭据端口（规格 S12 §7.5）：只读。
///
/// 供宿主自有存储（Keychain 等）接入——调用方只实现存取，快照 / 变更推送 /
/// 周期刷新 / 只读策略由 `StoreCredentials` 适配器承担。
///
/// 端口的 `async` 方法可能在协作线程池上执行，实现里的阻塞系统调用须自行放到
/// 专用队列（AGENTS 坑 #10）。
public protocol CredentialStore: Sendable {
    /// 读出全部条目；键须与 `Credential.key` 一致。抛出的错误原样透传给调用方。
    func load() async throws -> [String: Credential]
}

/// 可写凭据端口：在只读端口上追加写入（规格 S12 §7.5）。
///
/// 只读存储**无需**实现本协议——`StoreCredentials.update` 据此判定是否抛 `read-only`。
public protocol WritableCredentialStore: CredentialStore {
    /// 写入或覆盖一条凭据。
    func set(_ credential: Credential) async throws
}

/// 把 `CredentialStore` 端口套上完整 S12 语义的适配器（规格 S12 §7.5）。
///
/// `get` 同步读内存快照，首次须显式 `refresh()` 才入快照；`refreshInterval` 非空时
/// 首次拉取成功后起至多一个周期任务；`update` 在可写端口上**先落介质、再进快照**。
@ContextTreeActor
public final class StoreCredentials: Credentials {
    private let store: any CredentialStore
    private let snapshot = CredentialSnapshot()
    private let scheduler: RefreshScheduler

    public init(
        store: any CredentialStore,
        refreshInterval: TimeInterval? = nil,
        clock: any RefreshClock = TaskRefreshClock()
    ) {
        self.store = store
        scheduler = RefreshScheduler(interval: refreshInterval, clock: clock)
    }

    public var keys: [String] {
        snapshot.keys
    }

    public func get(_ key: String) -> Credential? {
        snapshot.get(key)
    }

    public func update(_ key: String, _ value: String) async throws {
        guard let writable = store as? any WritableCredentialStore else {
            throw CredentialsException(.readOnly, "该凭据来源是只读来源。")
        }
        let credential = Credential(key: key, value: value)
        // 介质领先内存：写入失败则快照不变，错误原样抛出。
        try await writable.set(credential)
        snapshot.update(credential)
    }

    public func refresh() async throws {
        let next = try await store.load()
        snapshot.refreshSnapshot(next)
        // 仅在首次拉取成功后起周期任务；重复 refresh 不叠加（RefreshScheduler 自守）。
        scheduler.schedule { [weak self] in
            try? await self?.refresh()
        }
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
