import Foundation
import SwiftusCore
import SwiftusFoundation
import Testing

@ContextTreeActor
final class EchoTool: Tool {
    let name = "echo"
    let description = "回显输入"
    let params: [ParamSpec] = [.string("text", required: true)]

    func call(_ context: ToolContext) async throws -> ToolResult {
        .success(try context.requireString("text"))
    }
}

@ContextTreeActor
private final class CrashTool: Tool {
    let name = "crash"
    let description = "必炸"

    func call(_ context: ToolContext) async throws -> ToolResult {
        throw ToolArgumentException("炸了")
    }
}

@ContextTreeActor
private final class SlowTool: Tool {
    let name = "slow"
    let description = "慢工具"
    let timeout: TimeInterval?

    init(timeout: TimeInterval? = nil) {
        self.timeout = timeout
    }

    func call(_ context: ToolContext) async throws -> ToolResult {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return .success("完成")
    }
}

/// 规格 S5 §6–§8:注册、白名单投影与执行管线。
@ContextTreeActor
@Suite("ToolRegistry 执行管线")
struct ToolRegistryTests {
    @Test("注册:同名抛错;Disposer 幂等且不误删新值")
    func registerGuards() throws {
        let registry = ToolRegistry()
        let first = try registry.register(EchoTool())
        #expect(throws: ToolRegistryError.duplicate("echo")) {
            try registry.register(EchoTool())
        }
        try first()
        #expect(registry.get("echo") == nil)
        try registry.register(EchoTool())
        try first()
        #expect(registry.get("echo") != nil)
        #expect(registry.names == ["echo"])
        #expect(registry.length == 1)
    }

    @Test("describe:白名单三键,宿主字段不外泄")
    func describeWhitelist() throws {
        let registry = ToolRegistry()
        try registry.register(EchoTool())
        let schema = try #require(registry.describeOne("echo"))
        #expect(schema.objectValue?.keys.sorted() == ["description", "name", "parameters"])
        #expect(schema["name"] == .string("echo"))
        #expect(schema["parameters"]?["required"] == .array([.string("text")]))
        #expect(registry.describe().count == 1)
    }

    @Test("未知工具与参数不合法:收敛为失败结果")
    func unknownAndInvalid() async {
        let registry = ToolRegistry()
        let unknown = await registry.call(ToolCall(name: "ghost"))
        #expect(unknown.failed)
        #expect(unknown.error?.code == ToolError.Codes.unknownTool)
        #expect(unknown.content == "未知工具 \"ghost\"")

        let registry2 = ToolRegistry()
        _ = try? registry2.register(EchoTool())
        let invalid = await registry2.call(ToolCall(name: "echo", arguments: ["text": .int(1)]))
        #expect(invalid.error?.code == ToolError.Codes.invalidArgs)
        #expect(invalid.content.hasPrefix("参数不合法："))
    }

    @Test("守卫拒绝与执行体异常")
    func deniedAndError() async throws {
        let registry = ToolRegistry()
        try registry.register(EchoTool())
        try registry.register(CrashTool())
        registry.addGuard { call in
            call.name == "echo" ? "echo 被拒绝" : nil
        }
        let denied = await registry.call(ToolCall(name: "echo", arguments: ["text": .string("x")]))
        #expect(denied.error?.code == ToolError.Codes.toolDenied)
        #expect(denied.content == "echo 被拒绝")

        let crashed = await registry.call(ToolCall(name: "crash"))
        #expect(crashed.error?.code == ToolError.Codes.toolError)
        #expect(crashed.content.contains("炸了"))
    }

    @Test("中间件:先注册者为最外层")
    func middlewareOrder() async throws {
        let registry = ToolRegistry()
        try registry.register(EchoTool())
        var order: [String] = []
        registry.use { _, next in
            order.append("m1-pre")
            let result = try await next()
            order.append("m1-post")
            return result
        }
        registry.use { _, next in
            order.append("m2-pre")
            let result = try await next()
            order.append("m2-post")
            return result
        }
        _ = await registry.call(ToolCall(name: "echo", arguments: ["text": .string("x")]))
        #expect(order == ["m1-pre", "m2-pre", "m2-post", "m1-post"])
    }

    @Test("超时:调用参数 > Tool.timeout > 注册表默认")
    func timeoutPriority() async throws {
        let registry = ToolRegistry(defaultTimeout: 10)
        try registry.register(SlowTool())
        let timedOut = await registry.call(ToolCall(name: "slow"), timeout: 0.05)
        #expect(timedOut.error?.code == ToolError.Codes.toolTimeout)
        #expect(timedOut.content == "工具 \"slow\" 超时（50ms）")

        let registry2 = ToolRegistry()
        try registry2.register(SlowTool(timeout: 0.05))
        let toolTimedOut = await registry2.call(ToolCall(name: "slow"))
        #expect(toolTimedOut.error?.code == ToolError.Codes.toolTimeout)

        let registry3 = ToolRegistry(defaultTimeout: 0.05)
        try registry3.register(SlowTool())
        let defaultTimedOut = await registry3.call(ToolCall(name: "slow"))
        #expect(defaultTimedOut.error?.code == ToolError.Codes.toolTimeout)
    }

    @Test("onResult 广播结局;onChange 在注册与注销后触发")
    func listeners() async throws {
        let registry = ToolRegistry()
        var results: [String] = []
        registry.onResult { call, result in
            results.append("\(call.name):\(result.failed)")
        }
        var changes = 0
        registry.onChange { changes += 1 }
        let disposer = try registry.register(EchoTool())
        _ = await registry.call(ToolCall(name: "echo", arguments: ["text": .string("hi")]))
        try disposer()
        #expect(results == ["echo:false"])
        #expect(changes == 2)
    }

    @Test("fn:一行注册闭包工具,同一条管线")
    func fnTool() async throws {
        let registry = ToolRegistry()
        try registry.fn("shout", description: "大写回显", params: [.string("text", required: true)]) { context in
            .success(try context.requireString("text").uppercased())
        }
        let result = await registry.call(ToolCall(name: "shout", arguments: ["text": .string("hi")]))
        #expect(result.failed == false)
        #expect(result.content == "HI")
        #expect(registry.describeOne("shout")?["description"] == .string("大写回显"))
    }
}
