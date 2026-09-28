import Foundation
import SwiftusCore

/// AWS Secrets Manager 连接配置（规格 S12 §7.4）。
public struct AwsSecretsConfig: Sendable {
    /// 访问密钥 ID（`AKIA…` / `ASIA…`）。
    public var accessKey: String
    /// 访问密钥密文。
    public var secretKey: String
    /// 区域（如 `us-east-1`），用于签名 scope 与默认端点。
    public var region: String
    /// Secret 名称或 ARN。
    public var secretId: String
    /// 临时凭证的会话令牌；非空时随 `X-Amz-Security-Token` 发送并参与签名。
    public var sessionToken: String?
    /// 自定义端点（VPC Endpoint / localstack / 测试替身）；缺省按 region 推导。
    public var endpoint: String?
    /// 定时刷新间隔（秒）；nil 表示只在显式 `refresh()` 时拉取。
    public var refreshInterval: TimeInterval?

    public init(
        accessKey: String,
        secretKey: String,
        region: String,
        secretId: String,
        sessionToken: String? = nil,
        endpoint: String? = nil,
        refreshInterval: TimeInterval? = nil
    ) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
        self.secretId = secretId
        self.sessionToken = sessionToken
        self.endpoint = endpoint
        self.refreshInterval = refreshInterval
    }
}

/// AWS Secrets Manager 凭据来源（规格 S12 §7.4）：只读，可定时刷新。
///
/// 拉取 `GetSecretValue`，读响应里的 `SecretString`；请求头经 S15 的 SigV4 签名
/// （service 固定 `secretsmanager`）。
@ContextTreeActor
public final class AwsSecretsCredentials: Credentials {
    /// SigV4 service 名（Secrets Manager 固定值）。
    public static let service = "secretsmanager"

    private let config: AwsSecretsConfig
    private let session: URLSession
    private let snapshot = CredentialSnapshot()
    private let scheduler: RefreshScheduler
    private let clock: @Sendable () -> Date

    public init(
        config: AwsSecretsConfig,
        session: URLSession = .shared,
        clock: any RefreshClock = TaskRefreshClock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.config = config
        self.session = session
        self.clock = now
        scheduler = RefreshScheduler(interval: config.refreshInterval, clock: clock)
    }

    /// 端点：缺省按 region 推导 `secretsmanager.<region>.amazonaws.com`。
    public var endpoint: URL? {
        URL(string: config.endpoint ?? "https://secretsmanager.\(config.region).amazonaws.com/")
    }

    /// 本次请求的签名器。
    public var signer: SigV4Signer {
        SigV4Signer(
            accessKey: config.accessKey,
            secretKey: config.secretKey,
            region: config.region,
            service: Self.service,
            sessionToken: config.sessionToken
        )
    }

    public var keys: [String] {
        snapshot.keys
    }

    public func get(_ key: String) -> Credential? {
        snapshot.get(key)
    }

    public func update(_ key: String, _ value: String) async throws {
        throw CredentialsException(.readOnly, "AWS 凭据是只读来源。")
    }

    public func refresh() async throws {
        guard let url = endpoint else {
            throw CredentialsException(.invalidSource, "Secrets Manager 端点非法：\(config.endpoint ?? "")")
        }
        let payload = Self.requestPayload(secretId: config.secretId)
        let headers = signer.sign(
            method: "POST",
            uri: url,
            headers: [
                "Content-Type": "application/x-amz-json-1.1",
                "X-Amz-Target": "secretsmanager.GetSecretValue",
            ],
            payload: payload,
            timestamp: clock()
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = Data(payload.utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CredentialsException(.awsNetwork, "访问 Secrets Manager 失败：\(error)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw CredentialsException(.awsHttp, "Secrets Manager 返回 HTTP \(status)。")
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

    /// 请求体 `{"SecretId": "…"}`。
    ///
    /// **必须与签名时的字节完全一致**（SigV4 签的是载荷哈希），故显式关掉
    /// `JSONSerialization` 默认的 `/` → `\/` 转义——Dart 的 `jsonEncode` 不转义
    /// 斜杠，两端载荷字节要一致，fixture 才能逐字节比对。
    static func requestPayload(secretId: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["SecretId": secretId],
            options: [.withoutEscapingSlashes]
        ) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// `SecretString` 先按 JSON 对象展开；展开为空时以 secretId 为单一键。
    private func parse(_ data: Data) -> [String: Credential] {
        guard let json = try? JSONValue.parse(data),
              let secret = json.objectValue?["SecretString"]?.stringValue else {
            return [:]
        }
        if let inner = try? JSONValue.parse(Data(secret.utf8)) {
            let expanded = parseCredentialMap(inner)
            if !expanded.isEmpty { return expanded }
        }
        return [config.secretId: Credential(key: config.secretId, value: secret)]
    }
}
