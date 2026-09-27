import SwiftusCore

/// 凭据契约：同步读内存快照，异步刷新（规格 S12 §6）。
///
/// 读取是同步的（读内存快照），远端来源用 refresh 把值拉进快照——
/// LLM Provider 之类需要在构造期同步解析 Key 的调用方不必改成异步形状。
@ContextTreeActor
public protocol Credentials: AnyObject {
    /// 按键取值；找不到或已过期返回 nil。
    func get(_ key: String) -> Credential?

    /// 写入一条凭据；只读来源抛 CredentialsException(.readOnly)。
    func update(_ key: String, _ value: String) async throws

    /// 登记变更监听，返回注销令牌。
    @discardableResult
    func addChangeListener(_ body: @escaping @ContextTreeActor (Credential) -> Void) -> Int

    /// 注销一个变更监听，返回是否确实移除了。
    @discardableResult
    func removeChangeListener(_ token: Int) -> Bool

    /// 当前快照中的键。
    var keys: [String] { get }

    /// 从底层来源重拉快照；默认无操作。
    func refresh() async

    /// 释放来源；幂等。
    func close()
}

extension Credentials {
    /// 按键取值；找不到或已过期抛 CredentialsException(.missing)。
    public func require(_ key: String) throws -> Credential {
        guard let credential = get(key) else {
            throw CredentialsException(.missing, "缺少凭据 \"\(key)\"。")
        }
        return credential
    }

    /// 校验若干键齐备：任一缺失即快速失败，消息列出全部缺失键。
    public func validate(_ requiredKeys: [String]) throws {
        let missing = requiredKeys.filter { get($0) == nil }
        guard !missing.isEmpty else { return }
        throw CredentialsException(.missing, "缺少凭据：\(missing.joined(separator: ", "))")
    }

    public func refresh() async {}
}

/// 'credentials' 服务键。
extension ServiceKey where Service == any Credentials {
    public static let credentials = ServiceKey<any Credentials>("credentials")
}

/// 将 Credentials 作为 'credentials' 服务提供到上下文；缺省为 EnvCredentials（规格 S12 §8）。
/// 服务随上下文释放而 close。
@ContextTreeActor
@discardableResult
public func provideCredentials(_ ctx: Context, credentials: (any Credentials)? = nil) throws -> any Credentials {
    let resolved = credentials ?? EnvCredentials()
    try ctx.provide(.credentials, resolved)
    ctx.onDispose { resolved.close() }
    return resolved
}
