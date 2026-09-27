import Foundation

/// JSONValue 桥接失败。
public enum JSONBridgeError: Error {
    /// 顶层不是合法 JSON 值。
    case invalidRoot
}

extension JSONValue {
    /// object 键访问；非 object 或缺键返回 nil。
    public subscript(key: String) -> JSONValue? {
        guard case let .object(dict) = self else { return nil }
        return dict[key]
    }

    /// array 下标访问；非 array 或越界返回 nil。
    public subscript(index: Int) -> JSONValue? {
        guard case let .array(items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    public var stringValue: String? {
        guard case let .string(text) = self else { return nil }
        return text
    }

    public var objectValue: [String: JSONValue]? {
        guard case let .object(dict) = self else { return nil }
        return dict
    }

    public var arrayValue: [JSONValue]? {
        guard case let .array(items) = self else { return nil }
        return items
    }

    public var intValue: Int? {
        guard case let .int(number) = self else { return nil }
        return Int(number)
    }

    // REASON: 形态名映射为静态映射表例外（全局 AGENTS.md §6）。
    /// 形态名（用于类型不符消息）：string / integer / number / boolean / object / array / null。
    public var shapeName: String {
        switch self {
        case .object: return "object"
        case .array: return "array"
        case .string: return "string"
        case .int: return "integer"
        case .double: return "number"
        case .bool: return "boolean"
        case .null: return "null"
        }
    }
}

extension JSONValue {
    // REASON: JSONValue 全形态映射为静态映射表例外（全局 AGENTS.md §6）。
    /// 桥接为 Foundation 对象（JSONSerialization 落笔用）。
    public var bridgedObject: Any {
        switch self {
        case let .object(dict):
            dict.mapValues { $0.bridgedObject }
        case let .array(items):
            items.map { $0.bridgedObject }
        case let .string(text):
            text
        case let .int(number):
            number
        case let .double(number):
            number
        case let .bool(flag):
            flag
        case .null:
            NSNull()
        }
    }

    // REASON: 同上，全形态映射例外；NSNumber 的 bool / int / double 判定见坑 #5。
    /// 从 JSONSerialization 产物解析；不支持的类型返回 nil。
    public init?(bridged object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.int64Value)
            }
        case let text as String:
            self = .string(text)
        case let dict as [String: Any]:
            self = .object(dict.compactMapValues { JSONValue(bridged: $0) })
        case let items as [Any]:
            self = .array(items.compactMap { JSONValue(bridged: $0) })
        default:
            return nil
        }
    }

    /// 序列化为 JSON 数据（键排序，输出确定）。
    public func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: bridgedObject, options: [.sortedKeys])
    }

    /// 从 JSON 数据解析；顶层非法时抛 JSONBridgeError.invalidRoot。
    public static func parse(_ data: Data) throws -> JSONValue {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let value = JSONValue(bridged: raw) else {
            throw JSONBridgeError.invalidRoot
        }
        return value
    }
}
