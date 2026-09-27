import SwiftusCore
import Testing

/// 规格 S3 §1–§3:敏感键判定、maskSecret 边界、递归脱敏。
@Suite("Redaction 脱敏")
struct RedactionTests {
    @Test("敏感键:词元命中与分段命中", arguments: [
        "API_KEY", "apiKey", "api-key", "token", "TOKENS", "authorization",
        "password", "PRIVATE_KEY", "access_secret", "credentials",
    ])
    func sensitive(key: String) {
        #expect(Redaction.sensitiveKey(key))
    }

    @Test("非敏感键:包含子串不算命中", arguments: [
        "username", "monkey", "message", "keyboard", "",
    ])
    func insensitive(key: String) {
        #expect(!Redaction.sensitiveKey(key))
    }

    @Test("maskSecret 边界", arguments: [
        ("", ""),
        ("abc", "***"),
        ("12345678", "********"),
        ("123456789", "1234...6789"),
        ("sk-1234567890abcdef", "sk-1...cdef"),
    ])
    func mask(input: String, expected: String) {
        #expect(Redaction.maskSecret(input) == expected)
    }

    @Test("递归脱敏:嵌套对象、数组与结构化敏感值")
    func recursive() {
        let input: JSONValue = .object([
            "user": .string("fitz"),
            "config": .object([
                "api_key": .string("sk-1234567890abcdef"),
                "retries": .int(3),
            ]),
            "tokens": .array([.string("abcdefgh12345"), .int(42)]),
            "nested_secret": .object(["inner": .string("x")]),
            "nothing": .null,
        ])
        let expected: JSONValue = .object([
            "user": .string("fitz"),
            "config": .object([
                "api_key": .string("sk-1...cdef"),
                "retries": .int(3),
            ]),
            "tokens": .string("***"),
            "nested_secret": .string("***"),
            "nothing": .null,
        ])
        #expect(Redaction.redactSecrets(input) == expected)
    }
}
