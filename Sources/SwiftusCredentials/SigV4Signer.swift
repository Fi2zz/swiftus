import CryptoKit
import Foundation

/// AWS Signature Version 4 签名器（规格 S15）。
///
/// 只覆盖 `Authorization` 头签法（**非** presigned URL），算法固定
/// `AWS4-HMAC-SHA256`。参与签名的头：业务头（键小写化）、`host`（取自 URI，
/// 只参与签名不回写）、`x-amz-date`、`x-amz-content-sha256`、可选的
/// `x-amz-security-token`。时间戳由调用方显式传入，故同一输入必然同一输出。
public struct SigV4Signer: Sendable {
    /// 访问密钥 ID（`AKIA…` / `ASIA…`）。
    public let accessKey: String
    /// 访问密钥密文。
    public let secretKey: String
    /// 区域（如 `us-east-1`），进入签名 scope。
    public let region: String
    /// 服务名（如 `secretsmanager`），进入签名 scope。
    public let service: String
    /// 临时凭证的会话令牌；非空时随 `X-Amz-Security-Token` 发送并参与签名。
    public let sessionToken: String?

    public init(
        accessKey: String,
        secretKey: String,
        region: String,
        service: String,
        sessionToken: String? = nil
    ) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
        self.service = service
        self.sessionToken = sessionToken
    }

    /// 对一次请求签名，返回**可原样发送**的完整头表。
    ///
    /// `headers` 是调用方打算发送的业务头，不含本方法生成的
    /// `Authorization` / `X-Amz-Date` / `X-Amz-Content-Sha256` /
    /// `X-Amz-Security-Token`。
    public func sign(
        method: String,
        uri: URL,
        headers: [String: String],
        payload: String,
        timestamp: Date
    ) -> [String: String] {
        let amzDate = Self.amzDate(timestamp)
        let payloadHash = Self.sha256Hex(payload)
        var signed: [String: String] = [:]
        for (name, value) in headers {
            signed[name.lowercased()] = value
        }
        signed["host"] = uri.host ?? ""
        signed["x-amz-date"] = amzDate
        signed["x-amz-content-sha256"] = payloadHash
        if let sessionToken {
            signed["x-amz-security-token"] = sessionToken
        }
        let names = signed.keys.sorted()
        let scope = "\(String(amzDate.prefix(8)))/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Self.canonicalRequest(
                method: method,
                uri: uri,
                signed: signed,
                names: names,
                payloadHash: payloadHash
            )),
        ].joined(separator: "\n")
        let signature = Self.hmacHex(
            key: Self.signingKey(
                secretKey: secretKey,
                dateStamp: String(amzDate.prefix(8)),
                region: region,
                service: service
            ),
            message: stringToSign
        )
        var signedHeaders = headers
        signedHeaders["X-Amz-Date"] = amzDate
        signedHeaders["X-Amz-Content-Sha256"] = payloadHash
        if let sessionToken {
            signedHeaders["X-Amz-Security-Token"] = sessionToken
        }
        signedHeaders["Authorization"] = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), "
            + "SignedHeaders=\(names.joined(separator: ";")), "
            + "Signature=\(signature)"
        return signedHeaders
    }

    // MARK: - 规范请求

    /// 规范请求六段（规格 S15 §2）。第六段是载荷哈希——它是独立的协议元素，
    /// 不依赖 `x-amz-content-sha256` 头是否存在，故单列参数。
    public static func canonicalRequest(
        method: String,
        uri: URL,
        signed: [String: String],
        names: [String],
        payloadHash: String
    ) -> String {
        let canonicalHeaders = names.map { "\($0):\(signed[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")" }
            .joined(separator: "\n") + "\n"
        return [
            method,
            canonicalURI(uri),
            canonicalQuery(uri),
            canonicalHeaders,
            names.joined(separator: ";"),
            payloadHash,
        ].joined(separator: "\n")
    }

    /// 规范 URI：按 `/` 切段（保留空段），逐段解码后再按 unreserved 集编码
    /// （规格 S15 §3）——避免对已编码的段二次编码（`%20` → `%2520`）。
    public static func canonicalURI(_ uri: URL) -> String {
        guard let components = URLComponents(url: uri, resolvingAgainstBaseURL: false) else {
            return "/"
        }
        let raw = components.percentEncodedPath
        if raw.isEmpty { return "/" }
        return raw
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { percentEncode(decodePathSegment(String($0))) }
            .joined(separator: "/")
    }

    /// 规范查询串：逐对「先解码再编码」（`+` 视为空格）后按整串排序（规格 S15 §4）。
    public static func canonicalQuery(_ uri: URL) -> String {
        guard let components = URLComponents(url: uri, resolvingAgainstBaseURL: false),
              let raw = components.percentEncodedQuery,
              !raw.isEmpty else {
            return ""
        }
        var pairs: [String] = []
        for part in raw.split(separator: "&") {
            let piece = String(part)
            let name: String
            let value: String
            if let index = piece.firstIndex(of: "=") {
                name = String(piece[piece.startIndex..<index])
                value = String(piece[piece.index(after: index)...])
            } else {
                name = piece
                value = ""
            }
            pairs.append("\(percentEncode(decodeQueryComponent(name)))=\(percentEncode(decodeQueryComponent(value)))")
        }
        return pairs.sorted().joined(separator: "&")
    }

    // MARK: - 时刻与摘要

    /// amzDate：UTC 紧凑格式 `YYYYMMDDTHHMMSSZ`（规格 S15 §1）。
    public static func amzDate(_ timestamp: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: timestamp
        )
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    /// 签名链：kDate → kRegion → kService → kSigning（规格 S15 §5）。
    public static func signingKey(secretKey: String, dateStamp: String, region: String, service: String) -> [UInt8] {
        var key = hmac(key: Array("AWS4\(secretKey)".utf8), message: dateStamp)
        key = hmac(key: key, message: region)
        key = hmac(key: key, message: service)
        return hmac(key: key, message: "aws4_request")
    }

    public static func sha256Hex(_ text: String) -> String {
        hexDigest(Array(SHA256.hash(data: Data(text.utf8))))
    }

    public static func hmac(key: [UInt8], message: String) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(key))
        ))
    }

    public static func hmacHex(key: [UInt8], message: String) -> String {
        hexDigest(hmac(key: key, message: message))
    }

    private static func hexDigest(_ bytes: [UInt8]) -> String {
        bytes.reduce(into: "") { result, byte in
            result += String(format: "%02x", byte)
        }
    }

    // MARK: - 百分号编码

    /// RFC 3986 unreserved 集（显式 ASCII 列举：`CharacterSet.alphanumerics` 含非 ASCII 字母）。
    static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        set.insert(charactersIn: "0123456789")
        set.insert(charactersIn: "-._~")
        return set
    }()

    public static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// 路径段解码：`+` 是字面量，只解百分号转义。
    private static func decodePathSegment(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    /// 查询分量解码：先 `+` → 空格（form 编码语义），再解百分号转义。
    private static func decodeQueryComponent(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
