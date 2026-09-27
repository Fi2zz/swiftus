import SwiftusCore
import SwiftusFoundation
import Testing

@ContextTreeActor
private final class ConfigTool: Tool {
    let name = "config"
    let description = "配置"
    let params: [ParamSpec] = [
        .string("host", required: true),
        .integer("port"),
        .number("ratio"),
        .enumeration("mode", ["fast", "slow"]),
        .array("tags", items: .string("tag", required: true)),
        .object("tls", properties: [.integer("version", required: true)]),
    ]

    func call(_ context: ToolContext) async throws -> ToolResult {
        .success("ok")
    }
}

/// 规格 S5 §5:validateToolArgs 的违规消息全集与递归路径。
@ContextTreeActor
@Suite("工具参数校验")
struct ToolValidationTests {
    private let tool = ConfigTool()

    private func violations(_ args: [String: JSONValue]) -> [String] {
        validateToolArgs(tool, args)
    }

    @Test("全部合规(含未声明的额外字段)通过")
    func allValid() {
        #expect(violations([
            "host": .string("x"),
            "port": .int(8080),
            "ratio": .double(0.5),
            "mode": .string("fast"),
            "tags": .array([.string("a")]),
            "tls": .object(["version": .int(3)]),
            "extra": .string("不校验"),
        ]).isEmpty)
    }

    @Test("缺必填 / 必填为 null / 类型不符 / number 接受整数")
    func basicViolations() {
        #expect(violations([:]) == ["缺少必填参数 \"host\""])
        #expect(violations(["host": .null]) == ["参数 \"host\" 不能为 null"])
        #expect(violations(["host": .string("x"), "port": .string("8080")]) == ["参数 \"port\" 期望 integer"])
        #expect(violations(["host": .string("x"), "ratio": .int(1)]).isEmpty)
        #expect(violations(["host": .string("x"), "ratio": .string("1")]) == ["参数 \"ratio\" 期望 number"])
    }

    @Test("枚举:非字符串与取值越界")
    func enumViolations() {
        #expect(violations(["host": .string("x"), "mode": .int(1)]) == ["参数 \"mode\" 期望 string 枚举"])
        #expect(violations(["host": .string("x"), "mode": .string("warp")])
            == ["参数 \"mode\" 取值不在 [fast, slow] 内"])
    }

    @Test("数组:元素类型与 required 元素的 null")
    func arrayViolations() {
        #expect(violations(["host": .string("x"), "tags": .int(1)]) == ["参数 \"tags\" 期望 array"])
        #expect(violations(["host": .string("x"), "tags": .array([.string("a"), .null])])
            == ["参数 \"tags[1]\" 不能为 null"])
        #expect(violations(["host": .string("x"), "tags": .array([.int(1)])])
            == ["参数 \"tags[0]\" 期望 string"])
    }

    @Test("对象:嵌套字段递归路径")
    func objectViolations() {
        #expect(violations(["host": .string("x"), "tls": .int(1)]) == ["参数 \"tls\" 期望 object"])
        #expect(violations(["host": .string("x"), "tls": .object([:])]) == ["缺少必填参数 \"tls.version\""])
        #expect(violations(["host": .string("x"), "tls": .object(["version": .string("3")])])
            == ["参数 \"tls.version\" 期望 integer"])
    }
}
