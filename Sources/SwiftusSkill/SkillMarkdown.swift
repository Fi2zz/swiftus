import Foundation
import SwiftusCore
import Yams

/// 已废弃的 camelCase 键：出现即整条丢弃（与 dsh 的语义一致）。
public let kSkillLegacyFrontmatterKeys: Set<String> = [
    "disableModelInvocation",
    "modelInvocable",
    "userInvocable",
]

/// 通过校验的 frontmatter（规格 S14 §2）。
public struct SkillFrontmatter: Sendable, Equatable {
    /// 技能名（kebab-case）。
    public let name: String

    /// 一行描述（构造时 trim）。
    public let description: String

    /// 适用时机的补充说明。
    public let whenToUse: String?

    /// 任意附加元数据，原样保留。
    public let metadata: [String: JSONValue]?

    /// 模型是否可以调用 `skill` 工具加载它。
    public let modelInvocable: Bool
}

/// 一次解析的结果：失败时 error 非空，调用方应丢弃该条目。
public struct SkillDocument: Sendable, Equatable {
    /// 通过校验的 frontmatter。
    public let frontmatter: SkillFrontmatter?

    /// 去 frontmatter 并 trim 后的正文。
    public let body: String

    /// 丢弃原因；为 nil 表示解析成功。
    public let error: String?

    public init(frontmatter: SkillFrontmatter? = nil, body: String = "", error: String? = nil) {
        self.frontmatter = frontmatter
        self.body = body
        self.error = error
    }
}

/// 解析一份技能文本（规格 S14 §2）。
public func parseSkillDocument(_ text: String) -> SkillDocument {
    guard let split = splitFrontmatter(text) else {
        return SkillDocument(error: "缺少 frontmatter：首行必须是 ---")
    }
    switch loadYamlMapping(split.source) {
    case let .invalid(message):
        return SkillDocument(error: message)
    case .notMapping:
        return SkillDocument(error: "frontmatter 必须是键值映射")
    case let .mapping(parsed):
        return documentFrom(parsed, body: split.body)
    }
}

/// frontmatter 切分：source（--- 之间的原文）与 body（去 frontmatter 后 trim）。
struct FrontmatterSplit {
    let source: String
    let body: String
}

func splitFrontmatter(_ text: String) -> FrontmatterSplit? {
    let lines = text.components(separatedBy: "\n")
    guard let first = lines.first, stripCr(first) == "---" else { return nil }
    for index in lines.indices.dropFirst() where stripCr(lines[index]) == "---" {
        return FrontmatterSplit(
            source: lines[1..<index].joined(separator: "\n"),
            body: lines[(index + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
    return nil
}

private func stripCr(_ line: String) -> String {
    line.hasSuffix("\r") ? String(line.dropLast()) : line
}

/// YAML 解析的三种结局。
private enum YamlOutcome {
    case mapping([String: JSONValue])
    case invalid(String)
    case notMapping
}

/// YAML 解析;非法 YAML 与非键值映射分开回报(规格 S14 §2 的两条不同文案)。
private func loadYamlMapping(_ source: String) -> YamlOutcome {
    let parsed: Any
    do {
        parsed = try Yams.load(yaml: source)
    } catch {
        return .invalid("frontmatter 不是合法 YAML：\(error)")
    }
    guard let dict = parsed as? [String: Any] else { return .notMapping }
    return .mapping(dict.mapValues { JSONValue(bridged: $0) ?? .null })
}

private func documentFrom(_ fields: [String: JSONValue], body: String) -> SkillDocument {
    if let rejection = rejectFields(fields) {
        return SkillDocument(error: rejection)
    }
    let name = fields["name"]?.stringValue ?? ""
    let description = (fields["description"]?.stringValue ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let disabled = (try? readBoolean(fields["disable-model-invocation"] ?? .bool(false))) ?? false
    return SkillDocument(
        frontmatter: SkillFrontmatter(
            name: name,
            description: description,
            whenToUse: optionalText(fields["whenToUse"]),
            metadata: fields["metadata"]?.objectValue,
            modelInvocable: !disabled
        ),
        body: body
    )
}

private func rejectFields(_ fields: [String: JSONValue]) -> String? {
    if let legacy = legacyKeyOf(fields) {
        return "frontmatter 用了旧键 \"\(legacy)\"，请改用规范键"
    }
    return invalidIdentity(fields) ?? invalidBoolean(fields)
}

private func legacyKeyOf(_ fields: [String: JSONValue]) -> String? {
    for legacy in kSkillLegacyFrontmatterKeys where fields.keys.contains(legacy) {
        return legacy
    }
    return nil
}

private func invalidIdentity(_ fields: [String: JSONValue]) -> String? {
    guard let name = fields["name"]?.stringValue, isSkillName(name) else {
        return "name 缺失或不是 kebab-case 技能名"
    }
    guard let description = fields["description"]?.stringValue,
          !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        return "description 缺失或为空"
    }
    return nil
}

private func invalidBoolean(_ fields: [String: JSONValue]) -> String? {
    do {
        _ = try readBoolean(fields["disable-model-invocation"] ?? .bool(false))
        return nil
    } catch let error as SkillFormatError {
        return error.message
    } catch {
        return nil
    }
}

/// 布尔文法错误。
struct SkillFormatError: Error {
    let message: String
}

/// 布尔文法：bool 直取;num 仅 1 / 0;字符串 trim + 小写后识别;其余报错(规格 S14 §2)。
func readBoolean(_ value: JSONValue) throws -> Bool {
    if case let .bool(flag) = value { return flag }
    if case let .int(number) = value, number == 1 || number == 0 { return number == 1 }
    if let text = value.stringValue {
        let normalized = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["true", "yes", "on", "1"].contains(normalized) { return true }
        if ["false", "no", "off", "0"].contains(normalized) { return false }
    }
    throw SkillFormatError(message: "不是合法布尔值：\(value.bridgedObject)")
}

private func optionalText(_ value: JSONValue?) -> String? {
    guard let text = value?.stringValue else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
