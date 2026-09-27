import SwiftusCore

/// 来源 `project-conatus`：项目根下的 `.conatus/skills`。
public let kSkillSourceProjectConatus = "project-conatus"

/// 来源 `project-agents`：项目根下的 `.agents/skills`。
public let kSkillSourceProjectAgents = "project-agents"

/// 来源 `custom`：调用方显式给出的目录。
public let kSkillSourceCustom = "custom"

/// 来源 `user-conatus`：`$CONATUS_HOME/skills`（缺省 `~/.conatus/skills`）。
public let kSkillSourceUserConatus = "user-conatus"

/// 来源 `user-agents`：`$CONATUS_AGENTS_HOME/skills`（缺省 `~/.agents/skills`）。
public let kSkillSourceUserAgents = "user-agents"

/// 来源 `runtime`：由宿主代码用 SkillRegistration 直接注册的技能。
public let kSkillSourceRuntime = "runtime"

/// provider 名 `filesystem`：目录发现型 provider。
public let kSkillFilesystemProvider = "filesystem"

/// provider 名 `runtime`：注册表内置的运行时技能。
public let kSkillRuntimeProvider = "runtime"

/// 运行时技能的层内权重：排在项目发现根（100/200）之后、自定义与用户根之前，
/// 因此项目声明可以覆盖宿主内建技能。
public let kSkillRuntimeRank = 250

/// 是否是合法的技能名：小写字母与数字，用 `-` 分隔（kebab-case）。
public func isSkillName(_ name: String) -> Bool {
    name.wholeMatch(of: /^[a-z0-9]+(?:-[a-z0-9]+)*$/) != nil
}

/// 一条技能的模型可见摘要（规格 S14 §1）。
public struct SkillSummary: Sendable, Equatable {
    /// 模型用来寻址的名字。
    public let name: String

    /// 一行路由描述，出现在技能目录里。
    public let description: String

    /// 适用时机的补充说明；nil 表示未声明。
    public let whenToUse: String?

    /// 来源标签，仅用于展示与诊断。
    public let source: String

    /// 提供该技能的 provider 名。
    public let provider: String

    /// 模型是否可以调用 `skill` 工具加载它。
    public let modelInvocable: Bool

    /// 技能文件路径（发现型 provider 才有）。
    public let path: String?

    public init(
        name: String,
        description: String,
        whenToUse: String? = nil,
        source: String,
        provider: String,
        modelInvocable: Bool = true,
        path: String? = nil
    ) {
        self.name = name
        self.description = description
        self.whenToUse = whenToUse
        self.source = source
        self.provider = provider
        self.modelInvocable = modelInvocable
        self.path = path
    }

    /// 规范 JSON 投影。
    public var json: JSONValue {
        var fields: [String: JSONValue] = [
            "name": .string(name),
            "description": .string(description),
        ]
        if let whenToUse { fields["whenToUse"] = .string(whenToUse) }
        fields["source"] = .string(source)
        fields["provider"] = .string(provider)
        fields["modelInvocable"] = .bool(modelInvocable)
        if let path { fields["path"] = .string(path) }
        return .object(fields)
    }
}

/// provider 产出的候选：摘要 + 层内排序权重。
public struct SkillCandidate: Sendable, Equatable {
    public let summary: SkillSummary

    /// 层内权重：数值小的先赢下同名。
    public let rank: Int

    public init(summary: SkillSummary, rank: Int = 0) {
        self.summary = summary
        self.rank = rank
    }
}

/// 运行时技能的注册请求。
public struct SkillRegistration: Sendable {
    public let name: String
    public let description: String
    public let whenToUse: String?

    /// 技能正文（去 frontmatter 的指令文本）。
    public let content: String

    /// 资源基址。
    public let resourceBase: SkillResourceBase?

    public init(
        name: String,
        description: String,
        whenToUse: String? = nil,
        content: String = "",
        resourceBase: SkillResourceBase? = nil
    ) {
        self.name = name
        self.description = description
        self.whenToUse = whenToUse
        self.content = content
        self.resourceBase = resourceBase
    }

    /// 注册表里的摘要投影。
    public var summary: SkillSummary {
        SkillSummary(
            name: name,
            description: description,
            whenToUse: whenToUse,
            source: kSkillSourceRuntime,
            provider: kSkillRuntimeProvider
        )
    }

    /// 注册表里的完整定义。
    public var definition: SkillDefinition {
        SkillDefinition(summary: summary, content: content, resourceBase: resourceBase)
    }
}

/// 一次 `skill` 调用的完整载荷：摘要 + 正文 + 资源基址。
public struct SkillDefinition: Sendable {
    public let summary: SkillSummary
    public let content: String
    public let resourceBase: SkillResourceBase?

    public init(summary: SkillSummary, content: String, resourceBase: SkillResourceBase? = nil) {
        self.summary = summary
        self.content = content
        self.resourceBase = resourceBase
    }
}

/// 技能附带资源的基址。
public enum SkillResourceBase: Sendable, Equatable {
    /// 资源位于某个目录：相对路径按它解析。
    case directory(String)
    /// 资源位于某个 URL：相对地址按它解析。
    case url(String)
    /// 资源由 provider 自行描述。
    case opaque(String)
}

/// provider 侧的失败：code 稳定可判，message 面向排障。
public struct SkillProviderException: Error, Equatable {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}
