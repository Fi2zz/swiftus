import Foundation
import SwiftusCore
import SwiftusFoundation

/// 技能里的一步：调用哪个工具、带什么参数（可含 `{{param}}` 占位符，规格 S16 §6.5）。
public struct SkillStep: Sendable, Equatable {
    /// 工具名。
    public let toolName: String
    /// 参数（字符串值里的 `{{name}}` 会被技能入参替换）。
    public let arguments: [String: JSONValue]

    public init(toolName: String, arguments: [String: JSONValue] = [:]) {
        self.toolName = toolName
        self.arguments = arguments
    }

    public init(jsonValue: JSONValue) {
        let object = jsonValue.objectValue ?? [:]
        toolName = object["toolName"]?.stringValue ?? ""
        arguments = object["arguments"]?.objectValue ?? [:]
    }

    public var jsonValue: JSONValue {
        .object([
            "toolName": .string(toolName),
            "arguments": .object(arguments),
        ])
    }
}

/// 技能的命名与描述。
public struct SkillMeta: Sendable, Equatable {
    /// 技能名（工具名）。
    public let name: String
    /// 技能描述。
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// 由「任务 + 工具序列」生成技能元信息。
public typealias SkillNamer = @ContextTreeActor (String, [String]) async throws -> SkillMeta

/// 由工具序列派生出的技能（规格 S16 §6.5，风险 medium）。
@ContextTreeActor
public final class SkillTool: Tool {
    /// 技能名。
    public let name: String
    /// 技能描述。
    public let description: String
    /// 编排好的步骤。
    public let steps: [SkillStep]
    /// 执行步骤用的工具注册表。
    public let tools: ToolRegistry
    /// 技能参数（由 `{{name}}` 占位符派生，除非显式传入）。
    public let params: [ParamSpec]

    public init(
        name: String,
        description: String,
        steps: [SkillStep],
        tools: ToolRegistry,
        params: [ParamSpec]? = nil
    ) {
        self.name = name
        self.description = description
        self.steps = steps
        self.tools = tools
        self.params = params ?? deriveSkillParams(steps)
    }

    public var riskLevel: ToolRisk {
        .medium
    }

    public func call(_ context: ToolContext) async throws -> ToolResult {
        var outputs: [JSONValue] = []
        for step in steps {
            var args: [String: JSONValue] = [:]
            for (key, value) in step.arguments {
                args[key] = resolveSkillArg(value, arguments: context.arguments)
            }
            let result = await tools.call(ToolCall(name: step.toolName, arguments: args))
            if result.failed {
                return .failure(
                    "技能 \"\(name)\" 在步骤 \(step.toolName) 失败：\(result.content)",
                    error: result.error
                )
            }
            outputs.append(.string(result.content))
        }
        return .success(outputs.last?.stringValue ?? "", value: .array(outputs))
    }

    /// 序列化为可持久化的记录。
    public var jsonValue: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "steps": .array(steps.map(\.jsonValue)),
        ])
    }

    /// 从记录恢复。
    public static func fromJson(_ value: JSONValue, tools: ToolRegistry) -> SkillTool {
        let object = value.objectValue ?? [:]
        return SkillTool(
            name: object["name"]?.stringValue ?? "",
            description: object["description"]?.stringValue ?? "",
            steps: (object["steps"]?.arrayValue ?? []).map(SkillStep.init(jsonValue:)),
            tools: tools
        )
    }
}

/// 扫描步骤参数里的 `{{name}}` 占位符，派生必填字符串参数（去重）。
public func deriveSkillParams(_ steps: [SkillStep]) -> [ParamSpec] {
    var names: Set<String> = []
    for step in steps {
        for value in step.arguments.values {
            guard case let .string(text) = value else { continue }
            for match in text.matches(of: /\{\{(\w+)\}\}/) {
                names.insert(String(match.output.1))
            }
        }
    }
    return names.sorted().map { ParamSpec.string($0, required: true) }
}

/// 把字符串里的 `{{name}}` 用技能入参替换（缺参保留占位符）；非字符串原样返回。
public func resolveSkillArg(_ value: JSONValue, arguments: [String: JSONValue]) -> JSONValue {
    guard case let .string(text) = value else { return value }
    var replaced = text
    for match in text.matches(of: /\{\{(\w+)\}\}/) {
        let placeholder = String(match.output.0)
        let name = String(match.output.1)
        let replacement = arguments[name].map { $0.stringValue ?? placeholder } ?? placeholder
        replaced = replaced.replacingOccurrences(of: placeholder, with: replacement)
    }
    return .string(replaced)
}
