import SwiftusCore
import SwiftusFoundation
import Testing

/// 规格 S6:注册、自动名、装配排序、渲染与插值。
@ContextTreeActor
@Suite("SystemPrompt 装配")
struct SystemPromptTests {
    @Test("同名重复注册抛错;Disposer 幂等移除")
    func duplicateAndDispose() throws {
        let prompt = SystemPrompt()
        let disposer = try prompt.section(PromptSection(name: "a", text: { "x" }))
        #expect(throws: SystemPromptError.duplicateSection("a")) {
            try prompt.section(PromptSection(name: "a", text: { "y" }))
        }
        #expect(throws: SystemPromptError.duplicateContext("c")) {
            try prompt.context(PromptContext(name: "c", text: { "1" }))
            try prompt.context(PromptContext(name: "c", text: { "2" }))
        }
        try disposer()
        try disposer()
        #expect(prompt.sectionList.isEmpty)
    }

    @Test("add 自动名:add-N 单调递增,remove 后不复用")
    func autoNames() throws {
        let prompt = SystemPrompt()
        let first = try prompt.add("一")
        let second = try prompt.add("二")
        #expect(first.name == "add-0")
        #expect(second.name == "add-1")
        #expect(prompt.remove("add-0"))
        #expect(!prompt.remove("add-0"))
        let third = try prompt.add("三")
        #expect(third.name == "add-2")
    }

    @Test("assemble:order 升序,同序按 name;provider 每次装配重求值")
    func assembleOrdering() throws {
        let prompt = SystemPrompt()
        var evaluations = 0
        try prompt.section(PromptSection(name: "z", order: 1) { "z" })
        try prompt.section(PromptSection(name: "b") {
            evaluations += 1
            return "b"
        })
        try prompt.section(PromptSection(name: "a") { "a" })
        let assembly = prompt.assemble()
        #expect(assembly.sections.map(\.name) == ["a", "b", "z"])
        _ = prompt.assemble()
        #expect(evaluations == 2)
    }

    @Test("render:插值后拼接,未知占位符原样保留")
    func renderInterpolate() throws {
        let prompt = SystemPrompt()
        try prompt.section(PromptSection(name: "a") { "你好 {{name}}" })
        try prompt.section(PromptSection(name: "b") { "{{unknown}} 与 {{name}}" })
        let assembly = prompt.assemble(variables: ["name": "fitz"])
        #expect(prompt.render(assembly) == "你好 fitz\n\n{{unknown}} 与 fitz")
        #expect(prompt.render(assembly, separator: "|") == "你好 fitz|{{unknown}} 与 fitz")
    }

    @Test("renderContexts:空文本不贡献内容")
    func renderContextsFiltersEmpty() throws {
        let prompt = SystemPrompt()
        try prompt.context(PromptContext(name: "empty") { "" })
        try prompt.context(PromptContext(name: "solid") { "有内容 {{who}}" })
        let assembly = prompt.assemble(variables: ["who": "我"])
        #expect(prompt.renderContexts(assembly) == "有内容 我")
    }

    @Test("段与上下文是独立命名空间")
    func separateNamespaces() throws {
        let prompt = SystemPrompt()
        try prompt.section(PromptSection(name: "same") { "段" })
        try prompt.context(PromptContext(name: "same") { "上下文" })
        #expect(prompt.sectionList.count == 1)
        #expect(prompt.contextList.count == 1)
    }
}
