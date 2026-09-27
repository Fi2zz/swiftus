import Foundation
import SwiftusCore
import SwiftusSkill
import Testing

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftus-skill-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeFile(_ root: URL, _ relative: String, _ content: String) throws {
    let file = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: file, atomically: true, encoding: .utf8)
}

private let sampleSkill = """
---
name: demo-skill
description: 演示技能
---
演示正文
"""

/// 规格 S14 §1 / §3:目录发现、只扫一层与正文加载。
@ContextTreeActor
@Suite("SkillFilesystemProvider 目录发现")
struct SkillFilesystemProviderTests {
    @Test("发现:子目录 SKILL.md 与顶层 *.md;只扫一层")
    func discovery() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, "pack/SKILL.md", sampleSkill)
        try writeFile(root, "loose.md", """
        ---
        name: loose-skill
        description: 散装
        ---
        散装正文
        """)
        try writeFile(root, "deep/nested/SKILL.md", sampleSkill.replacingOccurrences(of: "demo-skill", with: "deep-skill"))
        try writeFile(root, "notes.txt", "不是技能")
        let provider = SkillFilesystemProvider(roots: [
            SkillRoot(path: root.path, source: "test", rank: 100),
        ])
        let candidates = try await provider.list()
        // deep/nested/SKILL.md 是第二层,不被发现
        #expect(candidates.map(\.summary.name).sorted() == ["demo-skill", "loose-skill"])
        #expect(candidates.first { $0.summary.name == "demo-skill" }?.summary.source == "test")
        #expect(candidates.first { $0.summary.name == "demo-skill" }?.summary.path?.hasSuffix("pack/SKILL.md") == true)
    }

    @Test("根目录不存在返回空;坏文件跳过并上报")
    func missingRootAndBadFile() async throws {
        var warnings: [String] = []
        let provider = SkillFilesystemProvider(roots: [
            SkillRoot(path: "/nonexistent/path", source: "test", rank: 100),
        ], onWarning: { warnings.append($0) })
        #expect(try await provider.list().isEmpty)

        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(root, "bad.md", "没有 frontmatter")
        try writeFile(root, "good/SKILL.md", sampleSkill)
        let provider2 = SkillFilesystemProvider(roots: [
            SkillRoot(path: root.path, source: "test", rank: 100),
        ], onWarning: { warnings.append($0) })
        let candidates = try await provider2.list()
        #expect(candidates.map(\.summary.name) == ["demo-skill"])
        #expect(warnings.contains { $0.contains("被忽略") })
    }

    @Test("load:返回正文与目录资源基址;文件消失返回空")
    func loadDefinition() async throws {
        let root = try makeTempDir()
        let provider = SkillFilesystemProvider(roots: [
            SkillRoot(path: root.path, source: "test", rank: 100),
        ])
        try writeFile(root, "pack/SKILL.md", sampleSkill)
        let candidates = try await provider.list()
        let summary = try #require(candidates.first).summary
        let definition = try #require(try await provider.load(summary))
        #expect(definition.content == "演示正文")
        #expect(definition.resourceBase == .directory(root.appendingPathComponent("pack").path))

        try FileManager.default.removeItem(at: root)
        #expect(try await provider.load(summary) == nil)
        #expect(try await provider.load(SkillSummary(
            name: "x", description: "x", source: "t", provider: "filesystem"
        )) == nil)
    }

    @Test("defaultSkillRoots 与 findProjectRoot")
    func rootsDiscovery() throws {
        let roots = defaultSkillRoots(projectRoot: "/tmp/proj", includeUserRoots: false)
        #expect(roots.map(\.rank) == [100, 200])
        #expect(roots[0].path == "/tmp/proj/.conatus/skills")
        #expect(roots[1].source == kSkillSourceProjectAgents)

        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let nested = temp.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(findProjectRoot(from: nested.path) == nested.path)  // 无 .git 回退起始目录
        try FileManager.default.createDirectory(at: temp.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(findProjectRoot(from: nested.path) == temp.path)
    }
}
