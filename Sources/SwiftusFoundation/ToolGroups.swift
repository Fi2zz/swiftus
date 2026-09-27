import SwiftusCore

/// 工具分组与风险分级（规格 S5 §9）。
extension ToolRegistry {
    /// 按领域注册一组工具；返回幂等 Disposer（逆序撤销整组）。
    /// 同组内重复名或与既有工具重名抛错（与 register 同一口径）。
    @discardableResult
    public func group(_ name: String, _ groupTools: [any Tool]) throws -> Disposer {
        var disposers: [Disposer] = []
        for tool in groupTools {
            disposers.append(try register(tool))
            assignedGroups[tool.name] = name
        }
        var done = false
        return { [weak self] in
            guard let self, !done else { return }
            done = true
            for disposer in disposers.reversed() {
                try? disposer()
            }
            for tool in groupTools {
                self.assignedGroups.removeValue(forKey: tool.name)
            }
        }
    }

    /// 已登记的分组名（按工具注册顺序的首次出现）。
    public var groups: [String] {
        var result: [String] = []
        for name in names {
            guard let group = assignedGroups[name], !result.contains(group) else { continue }
            result.append(group)
        }
        return result
    }

    /// 某工具的分组：分组登记优先，否则回退 Tool.group。
    public func groupOf(_ name: String) -> String? {
        assignedGroups[name] ?? get(name)?.group
    }

    /// 某分组下的工具名（注册顺序）。
    public func namesIn(_ group: String) -> [String] {
        names.filter { groupOf($0) == group }
    }

    /// 某分组下工具的模型 schema。
    public func describeGroup(_ group: String) -> [JSONValue] {
        namesIn(group).compactMap { get($0)?.schema }
    }

    /// 只投影风险等级不高于 maxRisk 的工具 schema。
    public func describeWithin(_ maxRisk: ToolRisk) -> [JSONValue] {
        names.compactMap { name in
            guard let tool = get(name), tool.riskLevel <= maxRisk else { return nil }
            return tool.schema
        }
    }

    /// 能力分级守卫：拒绝风险等级高于 maxRisk 的工具调用；返回注销令牌。
    @discardableResult
    public func guardRisk(_ maxRisk: ToolRisk) -> Int {
        addGuard { [weak self] call in
            guard let tool = self?.get(call.name), tool.riskLevel > maxRisk else { return nil }
            return "工具 \"\(call.name)\" 风险等级 \(tool.riskLevel.label) 高于允许的 \(maxRisk.label)"
        }
    }
}
