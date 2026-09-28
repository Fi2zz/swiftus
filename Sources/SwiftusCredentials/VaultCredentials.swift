import Foundation
import SwiftusCore

/// HashiCorp Vault 连接配置（规格 S12 §7.3）。
public struct VaultConfig: Sendable {
    /// Vault 地址（如 `http://127.0.0.1:8200`）；末尾斜杠可有可无。
    public var address: String
    /// Vault Token，作为 `X-Vault-Token` 发送。
    public var token: String
    /// KV v2 路径（如 `conatus/llm`）。
    public var path: String
    /// KV 挂载点，默认 `secret`。
    public var mount: String
    /// 定时刷新间隔（秒）；nil 表示只在显式 `refresh()` 时拉取。
    public var refreshInterval: TimeInterval?

    public init(
        address: String,
        token: String,
        path: String,
        mount: String = "secret",
        refreshInterval: TimeInterval? = nil
    ) {
        self.address = address
        self.token = token
        self.path = path
        self.mount = mount
        self.refreshInterval = refreshInterval
    }
}

/// Vault KV v2 凭据来源（规格 S12 §7.3）：只读，可定时刷新。
///
/// 拉取 `GET {address}/v1/{mount}/data/{path}`，读响应里的 `data.data`。
@ContextTreeActor
public final class VaultCredentials: Credentials {
    private let config: VaultConfig
    private let session: URLSession
    private let snapshot = CredentialSnapshot()
    private let scheduler: RefreshScheduler

    public init(
        config: VaultConfig,
        session: URLSession = .shared,
        clock: any RefreshClock = TaskRefreshClock()
    ) {
        self.config = config
        self.session = session
        scheduler = RefreshScheduler(interval: config.refreshInterval, clock: clock)
    }

    /// 后端地址；传入的 `URLSession` 生命周期由调用方管理，这里不关闭。
    public var endpoint: URL? {
        let address = config.address.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return URL(string: "\(address)/v1/\(config.mount)/data/\(config.path)")
    }

    public var keys: [String] {
        snapshot.keys
    }

    public func get(_ key: String) -> Credential? {
        snapshot.get(key)
    }

    public func update(_ key: String, _ value: String) async throws {
        throw CredentialsException(.readOnly, "Vault 凭据是只读来源。")
    }

    public func refresh() async throws {
        guard let url = endpoint else {
            throw CredentialsException(.invalidSource, "Vault 地址非法：\(config.address)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(config.token, forHTTPHeaderField: "X-Vault-Token")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CredentialsException(.vaultNetwork, "访问 Vault 失败：\(error)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw CredentialsException(.vaultHttp, "Vault 返回 HTTP \(status)。")
        }
        snapshot.refreshSnapshot(parse(data))
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

    /// 解析响应：顶层 `data.data` 交给共用的凭据表口径；形状异常一律空表。
    private func parse(_ data: Data) -> [String: Credential] {
        guard let json = try? JSONValue.parse(data),
              let data0 = json.objectValue?["data"]?.objectValue,
              let inner = data0["data"] else {
            return [:]
        }
        return parseCredentialMap(inner)
    }
}
