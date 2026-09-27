/// 敏感信息脱敏：日志、事件与遥测中凭据绝不以明文出现（规格 S3 §1–§3）。
public enum Redaction {
    /// 敏感键词元表（键名按非字母数字拆分并转小写后的规范化形式）。
    private static let sensitiveTokens: Set<String> = [
        "key", "apikey", "token", "secret", "password", "passwd",
        "authorization", "credential", "credentials",
        "privatekey", "accesskey", "secretkey",
    ]

    /// 键名是否类似凭据字段：大小写不敏感，兼容下划线 / 连字符 / 驼峰（S3 §1）。
    public static func sensitiveKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        let normalized = String(lowered.filter(asciiAlnum))
        guard !normalized.isEmpty else { return false }
        if lookupToken(normalized) { return true }
        return lowered.split(whereSeparator: { !asciiAlnum($0) }).contains {
            lookupToken(String($0))
        }
    }

    /// 凭据的脱敏表示：前 4 位 + ... + 后 4 位；长度 ≤ 8 时等长全星号（S3 §2）。
    /// 长度与取位按 UTF-16 码元计，与 Dart `String.length` 对齐。
    public static func maskSecret(_ value: String) -> String {
        let units = Array(value.utf16)
        guard !units.isEmpty else { return "" }
        guard units.count > 8 else { return String(repeating: "*", count: units.count) }
        let head = String(decoding: units.prefix(4), as: UTF16.self)
        let tail = String(decoding: units.suffix(4), as: UTF16.self)
        return "\(head)...\(tail)"
    }

    /// 递归脱敏：敏感键的字符串值走 maskSecret，非字符串非 null 值替换为 ***；
    /// 不修改入参，返回新值（S3 §3）。
    public static func redactSecrets(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .object(dict):
            .object(Dictionary(uniqueKeysWithValues: dict.map {
                ($0.key, maskedValue(for: $0.key, $0.value))
            }))
        case let .array(items):
            .array(items.map(redactSecrets))
        default:
            value
        }
    }

    private static func maskedValue(for key: String, _ value: JSONValue) -> JSONValue {
        guard sensitiveKey(key) else { return redactSecrets(value) }
        switch value {
        case .null:
            return .null
        case let .string(text):
            return .string(maskSecret(text))
        default:
            return .string("***")
        }
    }

    private static func lookupToken(_ token: String) -> Bool {
        if sensitiveTokens.contains(token) { return true }
        return token.hasSuffix("s") && sensitiveTokens.contains(String(token.dropLast()))
    }

    private static func asciiAlnum(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}
