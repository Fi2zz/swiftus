/// 动态 JSON 的统一载体（方案书 §5.2）。
/// number 为 Int64 / Double 双形态，避免 int/double 边界精度问题（坑 #5）。
public enum JSONValue: Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
}
