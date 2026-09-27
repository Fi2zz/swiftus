import Foundation
import SwiftusCore

/// 凭据内存快照 + 变更广播，供各来源复用（规格 S12 §5）。
///
/// 快照把「值从哪来」（env / memory …）与「值怎么被消费」解耦：
/// 来源负责写入，消费方只读 get 并订阅变更监听。
@ContextTreeActor
public final class CredentialSnapshot {
    private var values: [String: Credential] = [:]
    private var listeners: [(token: Int, body: @ContextTreeActor (Credential) -> Void)] = []
    private var nextToken = 0

    /// 快照是否已关闭。
    public private(set) var closed = false

    public init() {}

    /// 快照中的键（副本）。
    public var keys: [String] {
        Array(values.keys)
    }

    /// 按键取值；不存在或已过期返回 nil（过期即视为没有）。
    public func get(_ key: String, now: Date = Date()) -> Credential? {
        guard let credential = values[key], !credential.expired(now: now) else { return nil }
        return credential
    }

    /// 写入一条凭据并推送变更；已关闭时忽略。
    public func update(_ credential: Credential) {
        guard !closed else { return }
        values[credential.key] = credential
        emit(credential)
    }

    /// 整体替换快照，并逐一推送新增或发生变化的凭据；移除无法表达，不推送。
    public func refreshSnapshot(_ next: [String: Credential]) {
        guard !closed else { return }
        let changed = next.values.filter(changedValue)
        values = next
        changed.forEach(emit)
    }

    /// 登记变更监听，返回注销令牌。
    @discardableResult
    public func addChangeListener(_ body: @escaping @ContextTreeActor (Credential) -> Void) -> Int {
        nextToken += 1
        listeners.append((token: nextToken, body: body))
        return nextToken
    }

    /// 注销一个变更监听，返回是否确实移除了。
    @discardableResult
    public func removeChangeListener(_ token: Int) -> Bool {
        guard let index = listeners.firstIndex(where: { $0.token == token }) else { return false }
        listeners.remove(at: index)
        return true
    }

    /// 关闭快照：幂等；关闭后写入与推送均被忽略。
    public func close() {
        guard !closed else { return }
        closed = true
        listeners.removeAll()
    }

    private func changedValue(_ credential: Credential) -> Bool {
        guard let previous = values[credential.key] else { return true }
        return previous.value != credential.value || previous.expiresAt != credential.expiresAt
    }

    private func emit(_ credential: Credential) {
        for entry in listeners {
            entry.body(credential)
        }
    }
}
