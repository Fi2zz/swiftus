import Foundation
import SwiftusCore

/// 一条凭据：键、明文值，以及可选的过期时刻（规格 S12 §1）。
public struct Credential: Sendable, Equatable {
    /// 凭据键名（如 `ARK_API_KEY`）。
    public let key: String

    /// 凭据明文值。**不要**写进日志或事件，用 masked。
    public let value: String

    /// 过期时刻；nil 表示永不过期。
    public let expiresAt: Date?

    public init(key: String, value: String, expiresAt: Date? = nil) {
        self.key = key
        self.value = value
        self.expiresAt = expiresAt
    }

    /// 脱敏表示（S3 §2），用于日志、事件与遥测。
    public var masked: String {
        Redaction.maskSecret(value)
    }

    /// 是否已过期：仅当 expiresAt 非空且早于给定时刻（过期即视为没有）。
    public func expired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt < now
    }
}

extension Credential: CustomStringConvertible {
    public var description: String {
        "Credential(\(key), \(masked))"
    }
}

/// 带稳定错误码的凭据异常（规格 S12 §2）。
public struct CredentialsException: Error, Equatable {
    /// 机器可路由的错误码。
    public enum Code: String, Sendable {
        case missing
        case readOnly = "read-only"
        case vaultHttp = "vault-http"
        case awsHttp = "aws-http"
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

extension CredentialsException: CustomStringConvertible {
    public var description: String {
        "CredentialsException(\(code.rawValue)): \(message)"
    }
}

/// 凭据来源类型（规格 S12 §3）。
public enum CredentialsSource: String, Sendable {
    case env, file, memory, vault, aws
}

/// 把 JSON 对象解析成凭据表；各来源共用口径（规格 S12 §4）。
public func parseCredentialMap(_ raw: JSONValue) -> [String: Credential] {
    guard case let .object(dict) = raw else { return [:] }
    return dict.reduce(into: [:]) { result, entry in
        guard let credential = parseCredential(key: entry.key, raw: entry.value) else { return }
        result[entry.key] = credential
    }
}

private func parseCredential(key: String, raw: JSONValue) -> Credential? {
    if let text = raw.stringValue {
        return Credential(key: key, value: text)
    }
    guard let object = raw.objectValue, let value = object["value"]?.stringValue else { return nil }
    return Credential(key: key, value: value, expiresAt: parseExpiry(object))
}

private func parseExpiry(_ object: [String: JSONValue]) -> Date? {
    guard let text = object["expiresAt"]?.stringValue else { return nil }
    return ISO8601DateFormatter().date(from: text)
}
