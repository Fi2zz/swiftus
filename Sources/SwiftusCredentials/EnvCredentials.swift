import Foundation
import SwiftusCore

/// 环境变量凭据：只读，进程启动即定形（规格 S12 §7）。
///
/// 构造时把全部**非空**环境变量装入快照；refresh 重读环境映射
/// （注入自定义 environment 时读注入的映射，供测试替身使用）。
@ContextTreeActor
public final class EnvCredentials: Credentials {
    private let environment: [String: String]
    private let snapshot = CredentialSnapshot()

    /// 缺省读进程环境。
    public init(environment: [String: String]? = nil) {
        self.environment = environment ?? ProcessInfo.processInfo.environment
        snapshot.refreshSnapshot(readAll())
    }

    public var keys: [String] {
        snapshot.keys
    }

    public func get(_ key: String) -> Credential? {
        snapshot.get(key)
    }

    public func update(_ key: String, _ value: String) async throws {
        throw CredentialsException(.readOnly, "环境变量凭据是只读来源。")
    }

    public func refresh() async throws {
        snapshot.refreshSnapshot(readAll())
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

    private func readAll() -> [String: Credential] {
        environment.reduce(into: [:]) { result, entry in
            guard !entry.value.isEmpty else { return }
            result[entry.key] = Credential(key: entry.key, value: entry.value)
        }
    }
}
