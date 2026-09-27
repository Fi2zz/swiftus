import Foundation
import SwiftusCore

/// 一个发现根：rank 小的先赢下同名技能（规格 S14 §1）。
public struct SkillRoot: Sendable, Equatable {
    /// 根目录路径。
    public let path: String

    /// 来源标签。
    public let source: String

    /// 层内权重。
    public let rank: Int

    public init(path: String, source: String, rank: Int) {
        self.path = path
        self.source = source
        self.rank = rank
    }
}

/// 默认发现根：项目根下的 `.conatus/skills`、`.agents/skills`，以及用户目录下
/// `$CONATUS_HOME/skills`、`$CONATUS_AGENTS_HOME/skills`（规格 S14 §1）。
public func defaultSkillRoots(projectRoot: String? = nil, includeUserRoots: Bool = true) -> [SkillRoot] {
    let root = projectRoot ?? findProjectRoot()
    var roots = [
        SkillRoot(path: "\(root)/.conatus/skills", source: kSkillSourceProjectConatus, rank: 100),
        SkillRoot(path: "\(root)/.agents/skills", source: kSkillSourceProjectAgents, rank: 200),
    ]
    guard includeUserRoots else { return roots }
    roots.append(SkillRoot(
        path: "\(homeUnder("CONATUS_HOME", fallback: ".conatus"))/skills",
        source: kSkillSourceUserConatus,
        rank: 400
    ))
    roots.append(SkillRoot(
        path: "\(homeUnder("CONATUS_AGENTS_HOME", fallback: ".agents"))/skills",
        source: kSkillSourceUserAgents,
        rank: 500
    ))
    return roots
}

/// 最近的含 `.git` 的祖先目录；找不到时返回起始目录（缺省当前工作目录）。
public func findProjectRoot(from: String? = nil) -> String {
    let fallback = from ?? FileManager.default.currentDirectoryPath
    var current = fallback
    while true {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: "\(current)/.git", isDirectory: &isDirectory)
        if exists, isDirectory.boolValue { return current }
        let parent = (current as NSString).deletingLastPathComponent
        guard parent != current else { return fallback }
        current = parent
    }
}

private func homeUnder(_ envKey: String, fallback: String) -> String {
    let fromEnv = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespaces)
    if let fromEnv, !fromEnv.isEmpty { return fromEnv }
    return "\(NSHomeDirectory())/\(fallback)"
}

/// 从发现根读取技能的 provider（规格 S14 §3）。
@ContextTreeActor
public final class SkillFilesystemProvider: SkillProvider {
    /// 发现根，按调用方给定顺序。
    public let roots: [SkillRoot]

    /// 条目级失败的上报出口。
    public let onWarning: (@ContextTreeActor (String) -> Void)?

    public init(roots: [SkillRoot], onWarning: (@ContextTreeActor (String) -> Void)? = nil) {
        self.roots = roots
        self.onWarning = onWarning
    }

    public var name: String {
        kSkillFilesystemProvider
    }

    public func list() async throws -> [SkillCandidate] {
        var candidates: [SkillCandidate] = []
        for root in roots {
            candidates.append(contentsOf: listRoot(root))
        }
        return candidates
    }

    public func load(_ summary: SkillSummary) async throws -> SkillDefinition? {
        guard let path = summary.path else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let document = parseSkillDocument(text)
        guard document.frontmatter != nil else { return nil }
        return SkillDefinition(
            summary: summary,
            content: document.body,
            resourceBase: .directory(url.deletingLastPathComponent().path)
        )
    }

    /// 只扫一层：目录条目取其中的 SKILL.md，文件条目取 *.md；按名字码位序处理。
    private func listRoot(_ root: SkillRoot) -> [SkillCandidate] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return entries.sorted().compactMap { candidateFrom(root, entry: $0) }
    }

    private func candidateFrom(_ root: SkillRoot, entry: String) -> SkillCandidate? {
        guard let file = skillFile(of: root.path, entry: entry) else { return nil }
        let document: SkillDocument
        do {
            document = parseSkillDocument(try String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8))
        } catch {
            onWarning?("技能文件 \(file) 读取失败：\(error)")
            return nil
        }
        guard let frontmatter = document.frontmatter else {
            if let error = document.error {
                onWarning?("技能文件 \(file) 被忽略：\(error)")
            }
            return nil
        }
        return SkillCandidate(summary: SkillSummary(
            name: frontmatter.name,
            description: frontmatter.description,
            whenToUse: frontmatter.whenToUse,
            source: root.source,
            provider: name,
            modelInvocable: frontmatter.modelInvocable,
            path: file
        ), rank: root.rank)
    }

    private func skillFile(of rootPath: String, entry: String) -> String? {
        let full = "\(rootPath)/\(entry)"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            let nested = "\(full)/SKILL.md"
            return FileManager.default.fileExists(atPath: nested) ? nested : nil
        }
        return full.hasSuffix(".md") ? full : nil
    }
}
