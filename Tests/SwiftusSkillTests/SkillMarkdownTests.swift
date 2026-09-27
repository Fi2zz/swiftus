import SwiftusCore
import SwiftusSkill
import Testing

private let validDocument = """
---
name: web-search
description: 搜索网页并总结
when_to_use: 需要联网时
disable-model-invocation: false
metadata:
  priority: 1
---
正文第一行

正文第二行
"""

/// 规格 S14 §2:SKILL.md 解析。
@Suite("SkillMarkdown 解析")
struct SkillMarkdownTests {
    @Test("合法文档:全字段解析,正文 trim")
    func validFull() {
        let document = parseSkillDocument(validDocument)
        #expect(document.error == nil)
        let frontmatter = document.frontmatter
        #expect(frontmatter?.name == "web-search")
        #expect(frontmatter?.description == "搜索网页并总结")
        #expect(frontmatter?.whenToUse == nil)  // when_to_use 下划线键非规范键,不进 whenToUse
        #expect(frontmatter?.metadata?["priority"] == .int(1))
        #expect(frontmatter?.modelInvocable == true)
        #expect(document.body == "正文第一行\n\n正文第二行")
    }

    @Test("whenToUse 规范键:trim 后为空视为未声明")
    func whenToUse() {
        let document = parseSkillDocument("""
        ---
        name: a-b
        description: x
        whenToUse: 用得着时
        ---
        正文
        """)
        #expect(document.frontmatter?.whenToUse == "用得着时")
        let blank = parseSkillDocument("""
        ---
        name: a-b
        description: x
        whenToUse: "  "
        ---
        正文
        """)
        #expect(blank.frontmatter?.whenToUse == nil)
    }

    @Test("disable-model-invocation 布尔文法")
    func booleanGrammar() {
        func invocable(_ raw: String) -> Bool? {
            parseSkillDocument("---\nname: a-b\ndescription: x\ndisable-model-invocation: \(raw)\n---\n正文")
                .frontmatter?.modelInvocable
        }
        #expect(invocable("true") == false)
        #expect(invocable("yes") == false)
        #expect(invocable("1") == false)
        #expect(invocable("false") == true)
        #expect(invocable("off") == true)
        #expect(invocable("0") == true)
        #expect(invocable("ON") == false)

        let invalid = parseSkillDocument("---\nname: a-b\ndescription: x\ndisable-model-invocation: 也许\n---\n正文")
        #expect(invalid.frontmatter == nil)
        #expect(invalid.error == "不是合法布尔值：也许")
    }

    @Test("缺首行 --- 与坏 YAML / 非映射分别报错")
    func structuralErrors() {
        #expect(parseSkillDocument("name: x").error == "缺少 frontmatter：首行必须是 ---")
        let badYaml = parseSkillDocument("---\nname: [未闭合\n---\n正文")
        #expect(badYaml.error?.hasPrefix("frontmatter 不是合法 YAML：") == true)
        let notMap = parseSkillDocument("---\n- a\n- b\n---\n正文")
        #expect(notMap.error == "frontmatter 必须是键值映射")
    }

    @Test("旧键、坏名字、空描述分别整条丢弃")
    func rejections() {
        #expect(parseSkillDocument("---\nname: a-b\ndescription: x\ndisableModelInvocation: true\n---\n正文").error
            == "frontmatter 用了旧键 \"disableModelInvocation\"，请改用规范键")
        #expect(parseSkillDocument("---\nname: A_B\ndescription: x\n---\n正文").error
            == "name 缺失或不是 kebab-case 技能名")
        #expect(parseSkillDocument("---\nname: a-b\ndescription: \"  \"\n---\n正文").error
            == "description 缺失或为空")
        #expect(parseSkillDocument("---\ndescription: x\n---\n正文").error
            == "name 缺失或不是 kebab-case 技能名")
    }

    @Test("CRLF 行尾容忍")
    func crlf() {
        let document = parseSkillDocument("---\r\nname: a-b\r\ndescription: x\r\n---\r\n正文")
        #expect(document.error == nil)
        #expect(document.frontmatter?.name == "a-b")
    }

    @Test("isSkillName 边界")
    func skillNames() {
        #expect(isSkillName("a"))
        #expect(isSkillName("web-search"))
        #expect(isSkillName("a1-b2"))
        #expect(!isSkillName("A"))
        #expect(!isSkillName("-ab"))
        #expect(!isSkillName("ab-"))
        #expect(!isSkillName("a_b"))
        #expect(!isSkillName("a b"))
        #expect(!isSkillName(""))
    }
}
