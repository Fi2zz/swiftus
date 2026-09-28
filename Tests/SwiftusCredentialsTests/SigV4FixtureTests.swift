import Foundation
import SwiftusCore
import SwiftusCredentials
import Testing

/// 规格 S15 golden fixtures：签名头表逐字段比对（Dart 侧行为为准绳）。
@Suite("S15 golden fixtures")
struct SigV4FixtureTests {
    @Test("sign", arguments: CredentialsFixtureLoader.load(kind: "sign"))
    func sign(_ fixture: CredentialsFixture) throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual = runSignCase(caseItem)
            expectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    private func runSignCase(_ caseItem: JSONValue) -> [String: JSONValue] {
        let request = caseItem["request"]?.objectValue ?? [:]
        guard let method = request["method"]?.stringValue,
              let uriText = request["uri"]?.stringValue,
              let uri = URL(string: uriText),
              let payload = request["payload"]?.stringValue,
              let timestampText = request["timestamp"]?.stringValue,
              let timestamp = parseInstant(timestampText) else {
            Issue.record("用例缺少可复现的请求要素：\(caseItem["label"]?.stringValue ?? "")")
            return [:]
        }
        var headers: [String: String] = [:]
        for (name, value) in request["headers"]?.objectValue ?? [:] {
            headers[name] = value.stringValue ?? ""
        }
        let signer = SigV4Signer(
            accessKey: "AKIDEXAMPLE",
            secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            region: request["region"]?.stringValue ?? "us-east-1",
            service: request["service"]?.stringValue ?? "secretsmanager",
            sessionToken: request["sessionToken"]?.stringValue
        )
        let signed = signer.sign(
            method: method,
            uri: uri,
            headers: headers,
            payload: payload,
            timestamp: timestamp
        )
        let parts = parseAuthorization(signed["Authorization"] ?? "")
        let signedHeaders = (parts["signedHeaders"]?.arrayValue ?? []).compactMap(\.stringValue)
        return [
            "headers": .object(signed.keys.sorted().reduce(into: [String: JSONValue]()) {
                $0[$1] = .string(signed[$1] ?? "")
            }),
            "authorization": .object(parts),
            "hostInSignedHeaders": .bool(signedHeaders.contains("host")),
            "hasHostHeader": .bool(signed["Host"] != nil),
        ]
    }

    /// `AWS4-HMAC-SHA256 Credential=<key>/<scope>, SignedHeaders=<names>, Signature=<sig>`
    /// ——固定三段结构，直接按分隔符切（不引正则，避免捕获组 API 的歧义）。
    private func parseAuthorization(_ text: String) -> [String: JSONValue] {
        let prefix = "AWS4-HMAC-SHA256 "
        guard text.hasPrefix(prefix) else { return ["raw": .string(text)] }
        let parts = text.dropFirst(prefix.count)
            .split(separator: ", ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let credential = splitValue(parts[0], "Credential="),
              let signedHeaders = splitValue(parts[1], "SignedHeaders="),
              let signature = splitValue(parts[2], "Signature=") else {
            return ["raw": .string(text)]
        }
        let scopeParts = credential.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard scopeParts.count == 2 else { return ["raw": .string(text)] }
        return [
            "algorithm": .string("AWS4-HMAC-SHA256"),
            "accessKey": .string(String(scopeParts[0])),
            "scope": .string(String(scopeParts[1])),
            "signedHeaders": .array(signedHeaders.split(separator: ";")
                .map { JSONValue.string(String($0)) }),
            "signature": .string(signature),
        ]
    }

    /// 去掉 `key=` 前缀后的值。
    private func splitValue(_ text: Substring, _ key: String) -> String? {
        guard text.hasPrefix(key) else { return nil }
        return String(text.dropFirst(key.count))
    }

    private func parseInstant(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: .iso8601)
    }
}
