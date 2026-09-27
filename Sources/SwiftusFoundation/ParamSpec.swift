import SwiftusCore

/// 参数类型（规格 S5 §3）。
public enum ParamType: Sendable {
    case string, integer, number, boolean, enumeration, array, object
}

/// 一个参数的声明：简单类型用对应静态工厂，枚举用 enumeration，
/// 数组用 array(items:)，对象用 object(properties:)（其嵌套 required 由子声明聚合）。
public struct ParamSpec: Sendable, Equatable {
    /// 参数名。
    public let name: String

    /// 参数类型。
    public let type: ParamType

    /// 面向模型的说明。
    public var description: String?

    /// 是否必填。
    public var required = false

    /// 枚举取值（仅 enumeration）。
    public var enumValues: [String] = []

    /// 元素声明（仅 array；经间接盒承载，值类型不能直接递归包含自身）。
    public var items: ParamSpecBox?

    /// 嵌套字段（仅 object；保持声明顺序）。
    public var properties: [ParamSpec] = []

    /// 默认值（schema 注解，不参与校验；工厂未覆盖的类型可在构造后赋值）。
    public var defaultValue: JSONValue?

    private init(name: String, type: ParamType) {
        self.name = name
        self.type = type
    }

    /// 字符串参数。
    public static func string(
        _ name: String, description: String? = nil, required: Bool = false, default defaultValue: String? = nil
    ) -> ParamSpec {
        make(name, type: .string, description: description, required: required, defaultValue: defaultValue.map(JSONValue.string))
    }

    /// 整数参数。
    public static func integer(
        _ name: String, description: String? = nil, required: Bool = false, default defaultValue: Int? = nil
    ) -> ParamSpec {
        make(name, type: .integer, description: description, required: required, defaultValue: defaultValue.map { JSONValue.int(Int64($0)) })
    }

    /// 数字参数（整数或小数）。
    public static func number(
        _ name: String, description: String? = nil, required: Bool = false, default defaultValue: Double? = nil
    ) -> ParamSpec {
        make(name, type: .number, description: description, required: required, defaultValue: defaultValue.map(JSONValue.double))
    }

    /// 布尔参数。
    public static func boolean(
        _ name: String, description: String? = nil, required: Bool = false, default defaultValue: Bool? = nil
    ) -> ParamSpec {
        make(name, type: .boolean, description: description, required: required, defaultValue: defaultValue.map(JSONValue.bool))
    }

    /// 字符串枚举参数；values 不能为空。
    public static func enumeration(
        _ name: String, _ values: [String], description: String? = nil, required: Bool = false
    ) -> ParamSpec {
        precondition(!values.isEmpty, "枚举取值不能为空")
        var spec = make(name, type: .enumeration, description: description, required: required, defaultValue: nil as JSONValue?)
        spec.enumValues = values
        return spec
    }

    /// 数组参数；items 声明元素类型。
    public static func array(
        _ name: String, items: ParamSpec, description: String? = nil, required: Bool = false
    ) -> ParamSpec {
        var spec = make(name, type: .array, description: description, required: required, defaultValue: nil as JSONValue?)
        spec.items = ParamSpecBox(items)
        return spec
    }

    /// 对象参数；properties 声明嵌套字段。
    public static func object(
        _ name: String, properties: [ParamSpec], description: String? = nil, required: Bool = false
    ) -> ParamSpec {
        var spec = make(name, type: .object, description: description, required: required, defaultValue: nil as JSONValue?)
        spec.properties = properties
        return spec
    }

    private static func make(
        _ name: String, type: ParamType, description: String?, required: Bool, defaultValue: JSONValue?
    ) -> ParamSpec {
        var spec = ParamSpec(name: name, type: type)
        spec.description = description
        spec.required = required
        spec.defaultValue = defaultValue
        return spec
    }

    /// 编译为单个 JSON Schema 片段（规格 S5 §3）。
    public var schemaFragment: JSONValue {
        var fields: [String: JSONValue] = ["type": .string(typeName)]
        applyEnumValues(&fields)
        applyItems(&fields)
        applyProperties(&fields)
        if let description { fields["description"] = .string(description) }
        if let defaultValue { fields["default"] = defaultValue }
        return .object(fields)
    }

    // REASON: 七类参数的类型名映射为静态映射表例外（全局 AGENTS.md §6）。
    private var typeName: String {
        switch type {
        case .string: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .enumeration: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private func applyEnumValues(_ fields: inout [String: JSONValue]) {
        guard type == .enumeration else { return }
        fields["enum"] = .array(enumValues.map(JSONValue.string))
    }

    private func applyItems(_ fields: inout [String: JSONValue]) {
        guard type == .array, let items else { return }
        fields["items"] = items.spec.schemaFragment
    }

    private func applyProperties(_ fields: inout [String: JSONValue]) {
        guard type == .object else { return }
        fields["properties"] = .object(Dictionary(uniqueKeysWithValues: properties.map {
            ($0.name, $0.schemaFragment)
        }))
        let nested = properties.filter(\.required).map(\.name)
        guard !nested.isEmpty else { return }
        fields["required"] = .array(nested.map(JSONValue.string))
    }
}

/// 元素声明的间接盒：值类型 ParamSpec 不能直接递归包含自身（array 的 items 用）。
public final class ParamSpecBox: Sendable {
    public let spec: ParamSpec

    public init(_ spec: ParamSpec) {
        self.spec = spec
    }
}

extension ParamSpecBox: Equatable {
    public static func == (lhs: ParamSpecBox, rhs: ParamSpecBox) -> Bool {
        lhs.spec == rhs.spec
    }
}

/// 把参数声明列表编译为模型可读的 type: object schema（规格 S5 §4）。
public func parameterSchema(_ params: [ParamSpec]) -> JSONValue {
    var schema: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object(Dictionary(uniqueKeysWithValues: params.map {
            ($0.name, $0.schemaFragment)
        })),
    ]
    let required = params.filter(\.required).map(\.name)
    guard !required.isEmpty else { return .object(schema) }
    schema["required"] = .array(required.map(JSONValue.string))
    return .object(schema)
}
