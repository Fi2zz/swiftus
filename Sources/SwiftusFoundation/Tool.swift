import Foundation
import SwiftusCore

/// 工具：声明形状（名字、简介、风险、分组、参数）并实现执行体（规格 S5）。
///
/// 取参失败抛 ToolArgumentException，由注册表统一收敛；执行体异常收敛为
/// TOOL_ERROR 失败结果，不向外传播。
@ContextTreeActor
public protocol Tool: AnyObject {
    /// 工具名（注册表键）。
    var name: String { get }

    /// 面向模型的简介。
    var description: String { get }

    /// 风险等级；默认只读。
    var riskLevel: ToolRisk { get }

    /// 所属分组；默认不分组。
    var group: String? { get }

    /// 该工具的超时；nil 表示沿用注册表的默认超时。
    var timeout: TimeInterval? { get }

    /// 声明哪些参数是文件系统路径（审批信任粒度）；默认空集。
    var pathParams: [String] { get }

    /// 参数声明；默认无参数。
    var params: [ParamSpec] { get }

    /// 执行一次调用。
    func call(_ context: ToolContext) async throws -> ToolResult
}

extension Tool {
    public var riskLevel: ToolRisk {
        .low
    }

    public var group: String? {
        nil
    }

    public var timeout: TimeInterval? {
        nil
    }

    public var pathParams: [String] {
        []
    }

    public var params: [ParamSpec] {
        []
    }

    /// 面向模型的白名单投影：只含 name / description / parameters（规格 S5 §2）。
    public var schema: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "parameters": parameterSchema(params),
        ])
    }
}
