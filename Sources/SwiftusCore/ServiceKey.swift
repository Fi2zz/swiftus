/// 抹型服务键：仅携带字符串 id，用于 inject 依赖列表等异构键场景（规格 S2 实现注记）。
public struct AnyServiceKey: Hashable, Sendable, ExpressibleByStringLiteral {
    public let id: String

    public init(_ id: String) {
        self.id = id
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }
}

/// 类型化服务键（phantom key）：编译期保类型、运行期保字符串兼容（规格 S2 实现注记）。
///
/// `Service` 应为非可选类型，避免「服务值为 nil」与「服务不存在」产生歧义。
public struct ServiceKey<Service>: Sendable, ExpressibleByStringLiteral {
    public let id: String

    public init(_ id: String) {
        self.id = id
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// 抹型形式，用于 inject 依赖列表与 contains 等只看 id 的场景。
    public var erased: AnyServiceKey {
        AnyServiceKey(id)
    }
}
