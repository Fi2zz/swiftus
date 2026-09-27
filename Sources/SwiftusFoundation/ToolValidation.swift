import SwiftusCore

/// 校验 args 是否满足 tool 的参数声明；返回违规说明列表，空 = 通过（规格 S5 §5）。
@ContextTreeActor
public func validateToolArgs(_ tool: any Tool, _ args: [String: JSONValue]) -> [String] {
    tool.params.compactMap { checkProperty($0, in: args, path: $0.name) }
}

private func checkProperty(_ spec: ParamSpec, in container: [String: JSONValue], path: String) -> String? {
    guard let raw = container[spec.name] else {
        return spec.required ? "缺少必填参数 \"\(path)\"" : nil
    }
    guard case .null = raw else { return checkValue(spec, raw, path: path) }
    return spec.required ? "参数 \"\(path)\" 不能为 null" : nil
}

// REASON: 七类参数分派为协议固定形态，属静态映射表例外（全局 AGENTS.md §6）。
private func checkValue(_ spec: ParamSpec, _ value: JSONValue, path: String) -> String? {
    switch spec.type {
    case .string:
        return value.stringValue == nil ? "参数 \"\(path)\" 期望 string" : nil
    case .integer:
        return value.intValue == nil ? "参数 \"\(path)\" 期望 integer" : nil
    case .number:
        return numberLike(value) ? nil : "参数 \"\(path)\" 期望 number"
    case .boolean:
        return boolLike(value) ? nil : "参数 \"\(path)\" 期望 boolean"
    case .enumeration:
        return checkEnum(spec, value, path: path)
    case .array:
        return checkArray(spec, value, path: path)
    case .object:
        return checkObject(spec, value, path: path)
    }
}

private func numberLike(_ value: JSONValue) -> Bool {
    switch value {
    case .int, .double:
        return true
    default:
        return false
    }
}

private func boolLike(_ value: JSONValue) -> Bool {
    guard case .bool = value else { return false }
    return true
}

private func checkEnum(_ spec: ParamSpec, _ value: JSONValue, path: String) -> String? {
    guard let text = value.stringValue else { return "参数 \"\(path)\" 期望 string 枚举" }
    guard spec.enumValues.contains(text) else {
        return "参数 \"\(path)\" 取值不在 [\(spec.enumValues.joined(separator: ", "))] 内"
    }
    return nil
}

private func checkArray(_ spec: ParamSpec, _ value: JSONValue, path: String) -> String? {
    guard let items = value.arrayValue else { return "参数 \"\(path)\" 期望 array" }
    guard let elementSpec = spec.items?.spec else { return nil }
    for (index, item) in items.enumerated() {
        if case .null = item {
            if elementSpec.required { return "参数 \"\(path)[\(index)]\" 不能为 null" }
            continue
        }
        if let issue = checkValue(elementSpec, item, path: "\(path)[\(index)]") { return issue }
    }
    return nil
}

private func checkObject(_ spec: ParamSpec, _ value: JSONValue, path: String) -> String? {
    guard let object = value.objectValue else { return "参数 \"\(path)\" 期望 object" }
    for child in spec.properties {
        if let issue = checkProperty(child, in: object, path: "\(path).\(child.name)") { return issue }
    }
    return nil
}
