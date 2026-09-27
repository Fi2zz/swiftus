import SwiftusCore

/// 可排序的注册项（规格 S6 §1 / §3）。
@ContextTreeActor
public protocol PromptEntry {
    /// 唯一名字（重复注册抛错）。
    var name: String { get }

    /// 排序权重（升序，缺省 0）。
    var order: Int { get }

    /// 文本 provider；每次装配都重新求值，可引用 {{variable}} 占位符。
    var text: @ContextTreeActor () -> String { get }
}

/// 一段可注册的 system prompt 段。
public struct PromptSection: PromptEntry {
    public let name: String
    public let order: Int
    public let text: @ContextTreeActor () -> String

    public init(name: String, order: Int = 0, text: @escaping @ContextTreeActor () -> String) {
        self.name = name
        self.order = order
        self.text = text
    }
}

/// 一份动态模型上下文，装配为独立贡献项；空串不贡献内容。
public struct PromptContext: PromptEntry {
    public let name: String
    public let order: Int
    public let text: @ContextTreeActor () -> String

    public init(name: String, order: Int = 0, text: @escaping @ContextTreeActor () -> String) {
        self.name = name
        self.order = order
        self.text = text
    }
}

/// 已解析的一段 prompt 段。
public struct AssembledSection: Sendable, Equatable {
    public let name: String
    public let text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

/// 已解析的一份动态上下文。
public struct AssembledContext: Sendable, Equatable {
    public let name: String
    public let text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

/// 一次装配的完整结果：段、上下文与插值变量。
public struct PromptAssembly: Sendable, Equatable {
    public let sections: [AssembledSection]
    public let contexts: [AssembledContext]
    public let variables: [String: String]

    public init(sections: [AssembledSection], contexts: [AssembledContext], variables: [String: String]) {
        self.sections = sections
        self.contexts = contexts
        self.variables = variables
    }
}

/// prompt 注册表错误。
public enum SystemPromptError: Error, Equatable {
    /// prompt 段同名重复注册：`prompt 段 "name" 已注册`。
    case duplicateSection(String)
    /// prompt 上下文同名重复注册：`prompt 上下文 "name" 已注册`。
    case duplicateContext(String)
}
