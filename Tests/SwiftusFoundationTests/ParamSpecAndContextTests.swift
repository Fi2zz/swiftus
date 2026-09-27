import SwiftusCore
import SwiftusFoundation
import Testing

/// 规格 S5 §3 / §4:ParamSpec 七类 schema 编译与顶层聚合。
@Suite("ParamSpec schema 编译")
struct ParamSpecTests {
    @Test("简单类型:type 名与注解")
    func simpleTypes() {
        #expect(ParamSpec.string("s").schemaFragment == .object(["type": .string("string")]))
        #expect(ParamSpec.integer("i").schemaFragment == .object(["type": .string("integer")]))
        #expect(ParamSpec.number("n").schemaFragment == .object(["type": .string("number")]))
        #expect(ParamSpec.boolean("b").schemaFragment == .object(["type": .string("boolean")]))

        let annotated = ParamSpec.string("s", description: "说明", default: "缺省").schemaFragment
        #expect(annotated["description"] == .string("说明"))
        #expect(annotated["default"] == .string("缺省"))
    }

    @Test("枚举:type 映射 string 并附 enum 取值")
    func enumeration() {
        let fragment = ParamSpec.enumeration("mode", ["a", "b"]).schemaFragment
        #expect(fragment["type"] == .string("string"))
        #expect(fragment["enum"] == .array([.string("a"), .string("b")]))
    }

    @Test("数组:items 为元素声明的递归片段")
    func array() {
        let fragment = ParamSpec.array("list", items: .string("item")).schemaFragment
        #expect(fragment["type"] == .string("array"))
        #expect(fragment["items"] == .object(["type": .string("string")]))
    }

    @Test("对象:properties 递归,嵌套 required 由子声明聚合")
    func object() {
        let fragment = ParamSpec.object("config", properties: [
            .integer("retry", required: true),
            .string("note"),
        ]).schemaFragment
        #expect(fragment["type"] == .string("object"))
        #expect(fragment["properties"]?["retry"]?["type"] == .string("integer"))
        #expect(fragment["required"] == .array([.string("retry")]))

        let optionalOnly = ParamSpec.object("config", properties: [.string("note")]).schemaFragment
        #expect(optionalOnly["required"] == nil)
    }

    @Test("parameterSchema:顶层 required 聚合;无必填不输出该字段")
    func topLevelSchema() {
        let schema = parameterSchema([.string("a", required: true), .integer("b")])
        #expect(schema["type"] == .string("object"))
        #expect(schema["required"] == .array([.string("a")]))
        #expect(schema["properties"]?["b"]?["type"] == .string("integer"))

        let noRequired = parameterSchema([.string("a")])
        #expect(noRequired["required"] == nil)
        #expect(parameterSchema([]) == .object([
            "type": .string("object"),
            "properties": .object([:]),
        ]))
    }
}

/// 规格 S5 注记:ToolContext 类型化取参与异常。
@Suite("ToolContext 取参")
struct ToolContextTests {
    private func context(_ arguments: [String: JSONValue]) -> ToolContext {
        ToolContext(ToolCall(name: "t", arguments: arguments))
    }

    @Test("contains:显式 null 值也算存在")
    func containsNull() {
        let context = context(["k": .null])
        #expect(context.contains("k"))
        #expect(!context.contains("missing"))
        #expect(context["k"] == .null)
    }

    @Test("可选访问器:不存在与 null 返回 nil,类型不符抛错")
    func optionalAccessors() throws {
        let context = context([
            "name": .string("fitz"),
            "count": .int(3),
            "ratio": .double(0.5),
            "verbose": .bool(true),
            "tags": .array([.string("x")]),
            "config": .object(["a": .int(1)]),
            "nothing": .null,
        ])
        #expect(try context.string("name") == "fitz")
        #expect(try context.string("missing") == nil)
        #expect(try context.string("nothing") == nil)
        #expect(try context.integer("count") == 3)
        #expect(try context.number("count") == 3.0)
        #expect(try context.number("ratio") == 0.5)
        #expect(try context.boolean("verbose") == true)
        #expect(try context.array("tags") == [.string("x")])
        #expect(try context.object("config") == ["a": .int(1)])

        #expect(throws: ToolArgumentException("参数 \"config\" 期望 string，实际 object")) {
            _ = try context.string("config")
        }
        #expect(throws: ToolArgumentException("参数 \"ratio\" 期望 integer，实际 number")) {
            _ = try context.integer("ratio")
        }
    }

    @Test("requireString:缺失与 null 分别报缺少必填与不能为 null")
    func requireString() throws {
        let context = context(["name": .string("fitz"), "nothing": .null])
        #expect(try context.requireString("name") == "fitz")
        #expect(throws: ToolArgumentException("缺少必填参数 \"missing\"")) {
            _ = try context.requireString("missing")
        }
        #expect(throws: ToolArgumentException("参数 \"nothing\" 不能为 null")) {
            _ = try context.requireString("nothing")
        }
    }
}
