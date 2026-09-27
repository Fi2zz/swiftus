import SwiftusCore

/// 参数缺失、类型不符或取值非法时抛出。
public struct ToolArgumentException: Error, Equatable {
    /// 人可读的失败说明。
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

extension ToolArgumentException: CustomStringConvertible {
    public var description: String {
        "ToolArgumentException: \(message)"
    }
}

/// 一次工具调用的类型安全参数视图（规格 S5 注记）。
public struct ToolContext: Sendable {
    /// 原始调用。
    public let call: ToolCall

    public init(_ call: ToolCall) {
        self.call = call
    }

    /// 解析后的参数对象。
    public var arguments: [String: JSONValue] {
        call.arguments
    }

    /// 调用标识。
    public var callId: String {
        call.callId
    }

    /// 参数是否存在（值可为 null）。
    public func contains(_ name: String) -> Bool {
        call.arguments.keys.contains(name)
    }

    /// 读取原始参数值。
    public subscript(name: String) -> JSONValue? {
        call.arguments[name]
    }

    /// 可选字符串。
    public func string(_ name: String) throws -> String? {
        try optional(name, expect: "string") { $0.stringValue }
    }

    /// 必填字符串。
    public func requireString(_ name: String) throws -> String {
        try required(name, string(name))
    }

    /// 可选整数。
    public func integer(_ name: String) throws -> Int? {
        try optional(name, expect: "integer") { $0.intValue }
    }

    /// 可选数字（整数也接受，统一转 Double）。
    public func number(_ name: String) throws -> Double? {
        try optional(name, expect: "number") { value in
            switch value {
            case let .int(number):
                Double(number)
            case let .double(number):
                number
            default:
                nil
            }
        }
    }

    /// 可选布尔。
    public func boolean(_ name: String) throws -> Bool? {
        try optional(name, expect: "boolean") { value in
            guard case let .bool(flag) = value else { return nil }
            return flag
        }
    }

    /// 可选数组。
    public func array(_ name: String) throws -> [JSONValue]? {
        try optional(name, expect: "array") { $0.arrayValue }
    }

    /// 可选对象。
    public func object(_ name: String) throws -> [String: JSONValue]? {
        try optional(name, expect: "object") { $0.objectValue }
    }

    /// 读取可选参数：不存在或为 null 返回 nil，类型不符抛 ToolArgumentException。
    private func optional<T>(_ name: String, expect: String, _ extract: (JSONValue) -> T?) throws -> T? {
        guard let raw = call.arguments[name] else { return nil }
        guard case .null = raw else {
            guard let value = extract(raw) else {
                throw ToolArgumentException("参数 \"\(name)\" 期望 \(expect)，实际 \(raw.shapeName)")
            }
            return value
        }
        return nil
    }

    /// 收敛必填语义：缺失、为 null 抛 ToolArgumentException。
    private func required<T>(_ name: String, _ value: T?) throws -> T {
        guard contains(name) else {
            throw ToolArgumentException("缺少必填参数 \"\(name)\"")
        }
        guard let value else {
            throw ToolArgumentException("参数 \"\(name)\" 不能为 null")
        }
        return value
    }
}
