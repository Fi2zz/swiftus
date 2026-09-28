import Foundation
import SwiftusCore
import SwiftusCredentials
import Testing

/// 规格 S12 v1.1 golden fixtures：文件 / Vault / AWS Secrets Manager 三来源。
///
/// 每个用例自带输入（文件内容 / 响应体 / 状态码 / 网络故障开关 / 连接配置），
/// Swift 侧据此驱动替身，产出与 Dart 侧同构的投影后逐字段比对。
@Suite("S12 v1.1 golden fixtures")
struct CredentialsRemoteFixtureTests {
    // MARK: 文件来源

    @Test("file-source", arguments: CredentialsFixtureLoader.load(kind: "file-source"))
    @ContextTreeActor
    func fileSource(_ fixture: CredentialsFixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = try await runFileCase(caseItem)
            expectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    @ContextTreeActor
    private func runFileCase(_ caseItem: JSONValue) async throws -> [String: JSONValue] {
        let input = caseItem["input"]?.objectValue ?? [:]
        var fallback: [String: String]?
        if let raw = input["fallback"]?.objectValue {
            fallback = raw.reduce(into: [String: String]()) { table, entry in
                table[entry.key] = entry.value.stringValue ?? ""
            }
        }
        if case "read-only" = caseItem["scenario"]?.stringValue ?? "" {
            let file = input["file"]?.stringValue ?? "two-forms.json"
            let credentials = FileCredentials(
                path: try writeTempFile(name: file, content: _twoFormsContent)
            )
            try await credentials.load()
            return ["code": .string(await catchCode { try await credentials.update("K", "v") })]
        }
        var results: [JSONValue] = []
        for spec in input["files"]?.arrayValue ?? [] {
            let name = spec["name"]?.stringValue ?? "creds.json"
            let content = spec["content"]?.stringValue
            let credentials = FileCredentials(
                path: try writeTempFile(name: name, content: content),
                fallback: fallback ?? [:]
            )
            let thrown = await catchCode { try await credentials.load() }
            results.append(.object([
                "file": .string(name),
                "snapshot": projectSnapshot(credentials),
                "keys": .array(credentials.keys.sorted().map { .string($0) }),
                "thrown": .string(normalizeThrownCode(thrown)),
            ]))
        }
        return ["results": .array(results)]
    }

    /// 与 fixtures 里 two-forms.json 同内容（用例自带 input 时优先用 input 的内容）。
    private var _twoFormsContent: String {
        "{\"ARK_API_KEY\":\"sk-file\",\"DEEPSEEK_API_KEY\":{\"value\":\"ds-file\",\"expiresAt\":\"2026-01-01T00:00:00Z\"},\"BAD_NUMBER\":42,\"BAD_OBJECT\":{\"noValue\":\"x\"}}"
    }

    // MARK: Vault 来源

    @Test("vault-source", arguments: CredentialsFixtureLoader.load(kind: "vault-source"))
    @ContextTreeActor
    func vaultSource(_ fixture: CredentialsFixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = try await runVaultCase(caseItem)
            expectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    @ContextTreeActor
    private func runVaultCase(_ caseItem: JSONValue) async throws -> [String: JSONValue] {
        let scenario = caseItem["scenario"]?.stringValue ?? ""
        let input = caseItem["input"]?.objectValue ?? [:]
        let config = VaultConfig(
            address: input["address"]?.stringValue ?? "http://127.0.0.1:8200/",
            token: input["token"]?.stringValue ?? "vault-token",
            path: input["path"]?.stringValue ?? "conatus/llm",
            mount: input["mount"]?.stringValue ?? "secret"
        )
        if scenario == "read-only" {
            let credentials = VaultCredentials(config: config, session: mockSession())
            let key = authority(of: credentials.endpoint) ?? ""
            MockURLProtocol.setHandler(authority: key, body: vaultDataBody)
            try await credentials.refresh()
            return ["code": .string(await catchCode { try await credentials.update("K", "v") })]
        }
        if scenario == "shape" {
            var results: [JSONValue] = []
            for body in input["bodies"]?.arrayValue ?? [] {
                let shaped = VaultCredentials(config: config, session: mockSession())
                let key = authority(of: shaped.endpoint) ?? ""
                MockURLProtocol.setHandler(authority: key, body: body.stringValue ?? "{}")
                results.append(await pullVault(shaped, authority: key))
            }
            return ["results": .array(results)]
        }
        let credentials = VaultCredentials(config: config, session: mockSession())
        let key = authority(of: credentials.endpoint) ?? ""
        MockURLProtocol.setHandler(
            authority: key,
            status: (input["status"]?.intValue).map { Int($0) } ?? 200,
            body: input["body"]?.stringValue ?? vaultDataBody,
            networkError: input["networkError"] == .bool(true)
        )
        let result = await pullVault(credentials, authority: key)
        return scenario == "refresh" ? ["result": result] : ["code": result["code"] ?? .null]
    }

    private let vaultDataBody = """
    {"data":{"data":{"ARK_API_KEY":"vault-key","DEEPSEEK_API_KEY":{"value":"ds-key"}}}}
    """

    @ContextTreeActor
    private func pullVault(_ credentials: VaultCredentials, authority: String) async -> JSONValue {
        let code = await catchCode { try await credentials.refresh() }
        return .object([
            "request": projectCapturedRequest(authority: authority),
            "snapshot": projectSnapshot(credentials),
            "keys": .array(credentials.keys.sorted().map { .string($0) }),
            "code": .string(code),
        ])
    }

    // MARK: AWS 来源

    @Test("aws-source", arguments: CredentialsFixtureLoader.load(kind: "aws-source"))
    @ContextTreeActor
    func awsSource(_ fixture: CredentialsFixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = try await runAwsCase(caseItem)
            expectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    @ContextTreeActor
    private func runAwsCase(_ caseItem: JSONValue) async throws -> [String: JSONValue] {
        let scenario = caseItem["scenario"]?.stringValue ?? ""
        let input = caseItem["input"]?.objectValue ?? [:]
        let config = AwsSecretsConfig(
            accessKey: input["accessKey"]?.stringValue ?? "AKIDEXAMPLE",
            secretKey: "SECRET",
            region: input["region"]?.stringValue ?? "us-east-1",
            secretId: "conatus/llm",
            sessionToken: input["sessionToken"]?.stringValue,
            endpoint: input["endpoint"]?.stringValue
        )
        let body = input["body"]?.stringValue
            ?? "{\"SecretString\":\"{\\\"ARK_API_KEY\\\":\\\"aws-key\\\"}\"}"
        // 签名时间固定，保证请求头可复现。
        let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_704_067_200) }
        if scenario == "read-only" {
            let credentials = AwsSecretsCredentials(config: config, session: mockSession(), now: now)
            let key = authority(of: credentials.endpoint) ?? ""
            MockURLProtocol.setHandler(authority: key, body: body)
            try await credentials.refresh()
            return ["code": .string(await catchCode { try await credentials.update("K", "v") })]
        }
        if scenario == "shape" {
            var results: [JSONValue] = []
            for shape in input["bodies"]?.arrayValue ?? [] {
                let shaped = AwsSecretsCredentials(config: config, session: mockSession(), now: now)
                let key = authority(of: shaped.endpoint) ?? ""
                MockURLProtocol.setHandler(authority: key, body: shape.stringValue ?? "{}")
                results.append(await pullAws(shaped, authority: key))
            }
            return ["results": .array(results)]
        }
        let credentials = AwsSecretsCredentials(config: config, session: mockSession(), now: now)
        let key = authority(of: credentials.endpoint) ?? ""
        MockURLProtocol.setHandler(
            authority: key,
            status: (input["status"]?.intValue).map { Int($0) } ?? 200,
            body: body,
            networkError: input["networkError"] == .bool(true)
        )
        let result = await pullAws(credentials, authority: key)
        return scenario == "http-error" || scenario == "network-error"
            ? ["code": result["code"] ?? .null]
            : ["result": result]
    }

    @ContextTreeActor
    private func pullAws(_ credentials: AwsSecretsCredentials, authority: String) async -> JSONValue {
        let code = await catchCode { try await credentials.refresh() }
        return .object([
            "request": projectCapturedRequest(authority: authority),
            "snapshot": projectSnapshot(credentials),
            "keys": .array(credentials.keys.sorted().map { .string($0) }),
            "code": .string(code),
        ])
    }
}

// MARK: - 替身与投影

/// 写出临时凭据文件；`content` 为 nil 时确保文件不存在。
func writeTempFile(name: String, content: String?) throws -> String {
    let dir = NSTemporaryDirectory() + "swiftus-s12-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/" + name
    if let content {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    } else if FileManager.default.fileExists(atPath: path) {
        try FileManager.default.removeItem(atPath: path)
    }
    return path
}

/// 按 authority 注册固定响应（状态码 / 响应体 / 网络故障开关）并返回会话。
///
/// authority 由来源自身的端点算出（见 `authority(of:)`），因此 fixture 声明的
/// 地址无需改动，桩也能按 authority 隔离并发用例。
func scriptedSession(
    authority: String,
    status: Int = 200,
    body: String = "{}",
    networkError: Bool = false
) -> URLSession {
    MockURLProtocol.setHandler(authority: authority, status: status, body: body, networkError: networkError)
    return mockSession()
}

/// 某 authority 上最近一次被拦截请求的投影（与导出器 `_requestShape` 同构）。
func projectCapturedRequest(authority: String) -> JSONValue {
    guard let captured = MockURLProtocol.lastRequest(authority: authority) else {
        return .object(["sent": .bool(false)])
    }
    var headers: [String: String] = [:]
    for (name, value) in captured.request.allHTTPHeaderFields ?? [:] {
        headers[name.lowercased()] = value
    }
    let body = captured.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
    return .object([
        "sent": .bool(true),
        "method": .string(captured.request.httpMethod ?? ""),
        "url": .string(captured.request.url?.absoluteString ?? ""),
        "contentType": headers["content-type"].map { .string($0) } ?? .null,
        "token": headers["x-vault-token"].map { .string($0) } ?? .null,
        "target": headers["x-amz-target"].map { .string($0) } ?? .null,
        "hasSessionToken": .bool(headers["x-amz-security-token"] != nil),
        "contentSha256": headers["x-amz-content-sha256"].map { .string($0) } ?? .null,
        "amzDateFormat": .bool(isAmzDate(headers["x-amz-date"])),
        "authorization": projectAuthorization(headers["authorization"]),
        "body": .string(body),
    ])
}

func isAmzDate(_ text: String?) -> Bool {
    guard let text else { return false }
    return text.range(of: #"^\d{8}T\d{6}Z$"#, options: .regularExpression) != nil
}

/// Authorization 头的稳定形状投影（日期与签名逐次变化，不入 fixture）。
///
/// 格式固定：`AWS4-HMAC-SHA256 Credential=<key>/<date>/<region>/<service>/aws4_request,
/// SignedHeaders=<names>, Signature=<sig>` —— 按分隔符切，不引正则。
func projectAuthorization(_ authorization: String?) -> JSONValue {
    guard let authorization else { return .object(["present": .bool(false)]) }
    let prefix = "AWS4-HMAC-SHA256 "
    guard authorization.hasPrefix(prefix) else {
        return .object(["present": .bool(true), "parsed": .bool(false)])
    }
    let parts = authorization.dropFirst(prefix.count)
        .split(separator: ", ", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3,
          let credential = stripPrefix(parts[0], "Credential="),
          let signedHeaders = stripPrefix(parts[1], "SignedHeaders="),
          let signature = stripPrefix(parts[2], "Signature=") else {
        return .object(["present": .bool(true), "parsed": .bool(false)])
    }
    // Credential = accessKey/date/region/service/aws4_request
    let scope = credential.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard scope.count == 5, scope[4] == "aws4_request" else {
        return .object(["present": .bool(true), "parsed": .bool(false)])
    }
    return .object([
        "present": .bool(true),
        "parsed": .bool(true),
        "algorithm": .string("AWS4-HMAC-SHA256"),
        "accessKey": .string(scope[0]),
        "dateStampFormat": .bool(isDateStamp(scope[1])),
        "region": .string(scope[2]),
        "service": .string(scope[3]),
        "scopeSuffix": .string("\(scope[2])/\(scope[3])/aws4_request"),
        "signedHeaders": .array(signedHeaders.split(separator: ";")
            .map { JSONValue.string(String($0)) }),
        "signatureLength": .int(Int64(signature.count)),
    ])
}

func stripPrefix(_ text: Substring, _ key: String) -> String? {
    guard text.hasPrefix(key) else { return nil }
    return String(text.dropFirst(key.count))
}

func isDateStamp(_ text: String) -> Bool {
    text.range(of: #"^\d{8}$"#, options: .regularExpression) != nil
}


