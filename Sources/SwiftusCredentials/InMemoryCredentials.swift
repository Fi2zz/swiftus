import SwiftusCore

/// 纯内存凭据：可写，update 立即生效并推送（规格 S12 §7）。
///
/// 适合进程内临时凭据、测试替身，或由外部同步流程写值的场景。
@ContextTreeActor
public final class InMemoryCredentials: Credentials {
    private let snapshot = CredentialSnapshot()

    /// 用 initial 建立初始快照。
    public init(initial: [String: String] = [:]) {
        snapshot.refreshSnapshot(Dictionary(uniqueKeysWithValues: initial.map {
            ($0.key, Credential(key: $0.key, value: $0.value))
        }))
    }

    public var keys: [String] {
        snapshot.keys
    }

    public func get(_ key: String) -> Credential? {
        snapshot.get(key)
    }

    public func update(_ key: String, _ value: String) async throws {
        snapshot.update(Credential(key: key, value: value))
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
        snapshot.close()
    }
}
